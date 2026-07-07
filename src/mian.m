#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import "DeviceInfo.h"

// ── 核心：免声明动态绑定 iOS 底层私有应用管理服务 ──
@interface NSObject (LSApplicationWorkspace_Private)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface NSObject (LSApplicationProxy_Private)
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

@interface ViewController : UIViewController <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 0伪装：开机首要任务，触发底层探针抓取真实的硬件底牌
    DeviceInfo *info = [DeviceInfo sharedInstance];
    NSLog(@"[总控] 自检就绪 -> iOS: %@, 机型: %@", info.systemVersion, info.deviceModel);
    
    // 2. 配置跨界通信管道，注册暗号监听器 "TrollHandler"
    WKUserContentController *userController = [[WKUserContentController alloc] init];
    [userController addScriptMessageHandler:self name:@"TrollHandler"];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.userContentController = userController;
    
    // 3. 初始化全屏 WebView 容器
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.05 alpha:1.0];
    self.webView.scrollView.bounces = NO; 
    [self.view addSubview:self.webView];
    
    // 4. 从 App Bundle 内部加载 HTML 页面
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
    if (url) {
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

// 📄 当网页加载完毕时，精准执行双重反向注入（硬件数据 + 真实App名单）
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    DeviceInfo *info = [DeviceInfo sharedInstance];
    
    // 注入 A：将硬件底牌送达前端看板
    NSString *jsDevice = [NSString stringWithFormat:@"window.updateDevicePayload('%@', '%@', '%@', '%@', %@, %@);",
                        info.systemVersion, info.deviceModel, info.serialNumber, info.processor,
                        info.isTrollStore ? @"true" : @"false", info.isJailbroken ? @"true" : @"false"];
    
    // 注入 B：动态抓取真实 App 列表并转为 JSON 字符串
    NSString *jsAppList = [NSString stringWithFormat:@"window.updateAppList('%@');", [self fetchUserAppListJSON]];
    
    // 延迟 0.5 秒，配合前端开屏飞入动画滑行完毕后完美灌入
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:jsDevice completionHandler:nil];
        [self.webView evaluateJavaScript:jsAppList completionHandler:nil];
        NSLog(@"[通信桥] 硬件基础数据与真实 App 矩阵链已全面焊死合拢。");
    });
}

// 🔍 利用私有 API 捞取全机第三方用户应用名单
- (NSString *)fetchUserAppListJSON {
    NSMutableArray *appArray = [NSMutableArray array];
    
    // 动态反射获取系统应用工作空间
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        NSArray *allApps = [workspace performSelector:@selector(allInstalledApplications)];
        
        for (id appProxy in allApps) {
            // 过滤系统原生组件，只抓取用户下载的第三方应用 (User)
            NSString *appType = [appProxy performSelector:@selector(applicationType)];
            if ([appType isEqualToString:@"User"]) {
                NSString *bundleID = [appProxy performSelector:@selector(applicationIdentifier)];
                NSString *appName = [appProxy performSelector:@selector(localizedName)];
                
                if (bundleID && appName) {
                    [appArray addObject:@{@"bundleID": bundleID, @"name": appName}];
                }
            }
        }
    }
    
    // 序列化为标准不带换行的 JSON 纯文本，供前端 JS 直接解析
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:appArray options:0 error:&error];
    if (!error && jsonData) {
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return @"[]";
}

// 📥 核心接收器：解析来自前端的多维度指令（支持字符串与复杂对象格式）
- (void)userContentController:(WKUserContentController *)userContentController 
      didReceiveScriptMessage:(WKScriptMessage *)message {
    
    id body = message.body;
    NSLog(@"[通信桥] 收到前端发来的原始载荷: %@", body);
    
    if ([body isKindOfClass:[NSString class]]) {
        // 兼容原有的无参数旧式轨暗号
        if ([body isEqualToString:@"start_idfa_loop"]) {
            [self executeRootHelperWithMode:@"bg_idfa_loop" selectedApps:nil];
        } else if ([body isEqualToString:@"start_clean"]) {
            [self executeRootHelperWithMode:@"standard_clean" selectedApps:nil];
        }
    } 
    else if ([body isKindOfClass:[NSDictionary class]]) {
        // ✨全新咬合：处理带勾选名单的高阶前端对象 {"action": "xxx", "apps": ["包名1", "包名2"]}
        NSString *action = body[@"action"];
        NSArray *apps = body[@"apps"];
        
        if ([action isEqualToString:@"start_clean"]) {
            [self executeRootHelperWithMode:@"standard_clean" selectedApps:apps];
        }
    }
}

// 🚀 动态派生提权进程（完美传递用户勾选的应用名单参数）
- (void)executeRootHelperWithMode:(NSString *)mode selectedApps:(NSArray *)selectedApps {
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"RootHelper" ofType:nil];
    if (!helperPath) return;
    
    // 构建 C 语言标准的 argv 动态参数列数组
    NSMutableArray *argsArray = [NSMutableArray array];
    [argsArray addObject:helperPath]; // argv[0] 是程序自身路径
    [argsArray addObject:mode];       // argv[1] 是运行模式轨
    
    // 将用户勾选的名单追加到 argv[2], argv[3]... 后面，实现数据物理咬合
    if (selectedApps && selectedApps.count > 0) {
        [argsArray addObjectsFromArray:selectedApps];
    }
    
    // 转为 C 指针分配内存
    int argc = (int)argsArray.count;
    const char **argv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        argv[i] = [argsArray[i] UTF8String];
    }
    argv[argc] = NULL; // 结构体结尾必须置空
    
    pid_t pid;
    int status = posix_spawn(&pid, argv[0], NULL, NULL, (char* const*)argv, NULL);
    
    free(argv); // 释放内存
    
    if (status == 0) {
        NSLog(@"[提权] 成功唤醒 RootHelper 并注入 %d 个动态名单参数 (PID: %d)", (argc - 2), pid);
    } else {
        NSLog(@"[降级] 普通沙盒环境提权被拒。");
    }
}

- (BOOL)prefersStatusBarHidden { return YES; }
@end

// ── 标准 AppDelegate 壳子 ──
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    ViewController *mainVC = [[ViewController alloc] init];
    self.window.rootViewController = mainVC;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
