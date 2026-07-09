#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <unistd.h>
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

// 【自锁开关闸】锁定后台 IDFA 轮询进程 PID，接通单按钮状态机
static pid_t global_bg_idfa_pid = 0;

@interface ViewController : UIViewController <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 0伪装：开机首要任务，触发底层探针抓取真实的硬件底牌
    DeviceInfo *info = [DeviceInfo sharedInstance];
    NSLog(@"[MAIN] Init complete. iOS: %@, Model: %@", info.systemVersion, info.deviceModel);
    
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
    // ✅ 修复：将 js 变量内中文字符改为干净的英文字符
    NSString *jsDevice = [NSString stringWithFormat:@"window.updateDevicePayload('%@', '%@', '%@', '%@', %@, %@);",
                        info.systemVersion, info.deviceModel, info.serialNumber, info.processor,
                        info.isTrollStore ? @"true" : @"false", info.isJailbroken ? @"true" : @"false"];
    
    // 注入 B：动态抓取真实 App 列表并转为 JSON 字符串
    NSString *jsAppList = [NSString stringWithFormat:@"window.updateAppList('%@');", [self fetchUserAppListJSON]];
    
    // 延迟 0.5 秒，配合前端开屏飞入动画滑行完毕后完美灌入
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:jsDevice completionHandler:nil];
        [self.webView evaluateJavaScript:jsAppList completionHandler:nil];
        NSLog(@"[BRIDGE] Data injected successfully.");
    });
}

// 🔍 利用私有 API 捞取全机所有应用名单（包括系统内置、第三方与隐藏服务，支持iOS全版本兼容）
- (NSString *)fetchUserAppListJSON {
    NSMutableArray *appArray = [NSMutableArray array];
    
    // 动态反射获取系统应用工作空间
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        @try {
            id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
            NSArray *allApps = nil;
            if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
                allApps = [workspace performSelector:@selector(allInstalledApplications)];
            } else if ([workspace respondsToSelector:@selector(allApplications)]) {
                allApps = [workspace performSelector:@selector(allApplications)];
            }
            
            for (id appProxy in allApps) {
                @try {
                    NSString *bundleID = nil;
                    if ([appProxy respondsToSelector:@selector(applicationIdentifier)]) {
                        bundleID = [appProxy performSelector:@selector(applicationIdentifier)];
                    } else if ([appProxy respondsToSelector:@selector(bundleIdentifier)]) {
                        bundleID = [appProxy performSelector:@selector(bundleIdentifier)];
                    }
                    
                    NSString *appName = nil;
                    if ([appProxy respondsToSelector:@selector(localizedName)]) {
                        appName = [appProxy performSelector:@selector(localizedName)];
                    }
                    
                    // 如果无法读取本地化名称，退而求其次使用 bundleID 尾部
                    if (!appName && bundleID) {
                        appName = [bundleID lastPathComponent];
                    }
                    
                    if (bundleID && appName) {
                        // 移除原有的 User/System 过滤，允许全部应用抓取到勾选面板
                        [appArray addObject:@{@"bundleID": bundleID, @"name": appName}];
                    }
                } @catch (NSException *e) {
                    NSLog(@"[ERROR] Skip parsing proxy record: %@", e);
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[ERROR] Failed to fetch application workspace: %@", e);
        }
    }
    
    // 按名称字母表排序，方便用户查找
    [appArray sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        return [obj1[@"name"] localizedCompare:obj2[@"name"]];
    }];
    
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
    NSLog(@"[BRIDGE] Payload received: %@", body);
    
    if ([body isKindOfClass:[NSString class]]) {
        if ([body isEqualToString:@"start_idfa_loop"]) {
            // 首次点击：派生后台进程并锁定 PID
            pid_t newPid = [self executeRootHelperWithMode:@"bg_idfa_loop" selectedApps:nil];
            if (newPid > 0) {
                global_bg_idfa_pid = newPid;
                [self.webView evaluateJavaScript:@"window.onIdfaStateChanged(true);" completionHandler:nil];
            }
        } else if ([body isEqualToString:@"stop_idfa_loop"]) {
            // 二次点击：下发 SIGKILL 物理截杀后台
            if (global_bg_idfa_pid > 0) {
                kill(global_bg_idfa_pid, SIGKILL);
                NSLog(@"[MAIN] Daemon process terminated (PID: %d)", global_bg_idfa_pid);
                global_bg_idfa_pid = 0;
            }
            [self.webView evaluateJavaScript:@"window.onIdfaStateChanged(false);" completionHandler:nil];
        } else if ([body isEqualToString:@"start_clean"]) {
            [self executeRootHelperWithMode:@"standard_clean" selectedApps:nil];
        }
    } 
    else if ([body isKindOfClass:[NSDictionary class]]) {
        // ✨全新咬合：处理带勾选名单的高阶前端对象 {"action": "xxx", "apps": ["包名1", "包名2"]}
        NSString *action = body[@"action"];
        
        if ([action isEqualToString:@"start_clean"]) {
            NSArray *apps = body[@"apps"];
            [self executeRootHelperWithMode:@"standard_clean" selectedApps:apps];
        } else if ([action isEqualToString:@"open_url"]) {
            NSString *urlString = body[@"url"];
            if (urlString) {
                NSURL *url = [NSURL URLWithString:urlString];
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        }
    }
}

// 🚀 动态派生提权进程（完美传递用户勾选的应用名单参数 + stdout 管道实时回传）
- (pid_t)executeRootHelperWithMode:(NSString *)mode selectedApps:(NSArray *)selectedApps {
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"RootHelper" ofType:nil];
    if (!helperPath) return 0;
    
    // 构建 C 语言标准的 argv 动态参数列数组
    NSMutableArray *argsArray = [NSMutableArray array];
    [argsArray addObject:helperPath]; // argv[0] 是程序自身路径
    [argsArray addObject:mode];       // argv[1] 是运行模式轨
    
    // 将用户勾选的名单追加到 argv[2], argv[3]... 后面，实现数据物理咬合
    if (selectedApps && selectedApps.count > 0) {
        [argsArray addObjectsFromArray:selectedApps];
    }
    
    // 转为 C 指针分配内存
    int argCount = (int)argsArray.count;
    const char **argv = calloc(argCount + 1, sizeof(char *));
    for (int i = 0; i < argCount; i++) {
        argv[i] = [argsArray[i] UTF8String];
    }
    argv[argCount] = NULL; // 结构体结尾必须置空
    
    // 建立管道，接通 RootHelper 的 stdout 实时日志流
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        free(argv);
        return 0;
    }
    
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    
    pid_t pid;
    int status = posix_spawn(&pid, argv[0], &actions, NULL, (char* const*)argv, NULL);
    
    posix_spawn_file_actions_destroy(&actions);
    free(argv);
    close(pipefd[1]); // 父进程关闭管道写端
    
    if (status == 0) {
        NSLog(@"[SPAWN] RootHelper launched with %d targets (PID: %d)", (argCount - 2), pid);
        
        // 异步读取管道，将 RootHelper 的 stdout 实时转发至前端 WebView 日志面板
        int readFd = pipefd[0];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            FILE *stream = fdopen(readFd, "r");
            if (!stream) { close(readFd); return; }
            
            char buffer[1024];
            while (fgets(buffer, sizeof(buffer), stream) != NULL) {
                NSString *line = [[NSString alloc] initWithUTF8String:buffer];
                // 去除行尾换行
                line = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if (line.length == 0) continue;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 转义单引号防止 JS 注入崩溃
                    NSString *escaped = [line stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                    NSString *js = [NSString stringWithFormat:@"appendLog('%@', 'system');", escaped];
                    [self.webView evaluateJavaScript:js completionHandler:nil];
                });
            }
            fclose(stream);
        });
        
        return pid;
    } else {
        NSLog(@"[ERROR] sandbox restricted.");
        close(pipefd[0]);
        return 0;
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
