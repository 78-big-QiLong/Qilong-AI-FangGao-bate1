#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <unistd.h>
#import "DeviceInfo.h"

// 鈹€鈹€ 鏍稿績锛氬厤澹版槑鍔ㄦ€佺粦瀹?iOS 搴曞眰绉佹湁搴旂敤绠＄悊鏈嶅姟 鈹€鈹€
@interface NSObject (LSApplicationWorkspace_Private)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface NSObject (LSApplicationProxy_Private)
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

// 銆愯嚜閿佸紑鍏抽椄銆戦攣瀹氬悗鍙?IDFA 杞杩涚▼ PID锛屾帴閫氬崟鎸夐挳鐘舵€佹満
static pid_t global_bg_idfa_pid = 0;

@interface ViewController : UIViewController <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 0浼锛氬紑鏈洪瑕佷换鍔★紝瑙﹀彂搴曞眰鎺㈤拡鎶撳彇鐪熷疄鐨勭‖浠跺簳鐗?
    DeviceInfo *info = [DeviceInfo sharedInstance];
    NSLog(@"[MAIN] Init complete. iOS: %@, Model: %@", info.systemVersion, info.deviceModel);
    
    // 2. 閰嶇疆璺ㄧ晫閫氫俊绠￠亾锛屾敞鍐屾殫鍙风洃鍚櫒 "TrollHandler"
    WKUserContentController *userController = [[WKUserContentController alloc] init];
    [userController addScriptMessageHandler:self name:@"TrollHandler"];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.userContentController = userController;
    
    // 3. 鍒濆鍖栧叏灞?WebView 瀹瑰櫒
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.05 alpha:1.0];
    self.webView.scrollView.bounces = NO; 
    [self.view addSubview:self.webView];
    
    // 4. 浠?App Bundle 鍐呴儴鍔犺浇 HTML 椤甸潰
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
    if (url) {
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

// 馃搫 褰撶綉椤靛姞杞藉畬姣曟椂锛岀簿鍑嗘墽琛屽弻閲嶅弽鍚戞敞鍏ワ紙纭欢鏁版嵁 + 鐪熷疄App鍚嶅崟锛?
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    DeviceInfo *info = [DeviceInfo sharedInstance];
    
    // 娉ㄥ叆 A锛氬皢纭欢搴曠墝閫佽揪鍓嶇鐪嬫澘
    // 鉁?淇锛氬皢 js 鍙橀噺鍐呬腑鏂囧瓧绗︽敼涓哄共鍑€鐨勮嫳鏂囧瓧绗?
    NSString *jsDevice = [NSString stringWithFormat:@"window.updateDevicePayload('%@', '%@', '%@', '%@', %@, %@);",
                        info.systemVersion, info.deviceModel, info.serialNumber, info.processor,
                        info.isTrollStore ? @"true" : @"false", info.isJailbroken ? @"true" : @"false"];
    
    // 娉ㄥ叆 B锛氬姩鎬佹姄鍙栫湡瀹?App 鍒楄〃骞惰浆涓?JSON 瀛楃涓?
    NSString *jsAppList = [NSString stringWithFormat:@"window.updateAppList('%@');", [self fetchUserAppListJSON]];
    
    // 寤惰繜 0.5 绉掞紝閰嶅悎鍓嶇寮€灞忛鍏ュ姩鐢绘粦琛屽畬姣曞悗瀹岀編鐏屽叆
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:jsDevice completionHandler:nil];
        [self.webView evaluateJavaScript:jsAppList completionHandler:nil];
        NSLog(@"[BRIDGE] Data injected successfully.");
    });
}

// 馃攳 鍒╃敤绉佹湁 API 鎹炲彇鍏ㄦ満鎵€鏈夊簲鐢ㄥ悕鍗曪紙鍖呮嫭绯荤粺鍐呯疆銆佺涓夋柟涓庨殣钘忔湇鍔★紝鏀寔iOS鍏ㄧ増鏈吋瀹癸級
- (NSString *)fetchUserAppListJSON {
    NSMutableArray *appArray = [NSMutableArray array];
    
    // 鍔ㄦ€佸弽灏勮幏鍙栫郴缁熷簲鐢ㄥ伐浣滅┖闂?
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
                    
                    // 濡傛灉鏃犳硶璇诲彇鏈湴鍖栧悕绉帮紝閫€鑰屾眰鍏舵浣跨敤 bundleID 灏鹃儴
                    if (!appName && bundleID) {
                        appName = [bundleID lastPathComponent];
                    }
                    
                    if (bundleID && appName) {
                        // 绉婚櫎鍘熸湁鐨?User/System 杩囨护锛屽厑璁稿叏閮ㄥ簲鐢ㄦ姄鍙栧埌鍕鹃€夐潰鏉?
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
    
    // 鎸夊悕绉板瓧姣嶈〃鎺掑簭锛屾柟渚跨敤鎴锋煡鎵?
    [appArray sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        return [obj1[@"name"] localizedCompare:obj2[@"name"]];
    }];
    
    // 搴忓垪鍖栦负鏍囧噯涓嶅甫鎹㈣鐨?JSON 绾枃鏈紝渚涘墠绔?JS 鐩存帴瑙ｆ瀽
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:appArray options:0 error:&error];
    if (!error && jsonData) {
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return @"[]";
}

// 馃摜 鏍稿績鎺ユ敹鍣細瑙ｆ瀽鏉ヨ嚜鍓嶇鐨勫缁村害鎸囦护锛堟敮鎸佸瓧绗︿覆涓庡鏉傚璞℃牸寮忥級
- (void)userContentController:(WKUserContentController *)userContentController 
      didReceiveScriptMessage:(WKScriptMessage *)message {
    
    id body = message.body;
    NSLog(@"[BRIDGE] Payload received: %@", body);
    
    if ([body isKindOfClass:[NSString class]]) {
        if ([body isEqualToString:@"start_idfa_loop"]) {
            // 棣栨鐐瑰嚮锛氭淳鐢熷悗鍙拌繘绋嬪苟閿佸畾 PID
            pid_t newPid = [self executeRootHelperWithMode:@"bg_idfa_loop" selectedApps:nil];
            if (newPid > 0) {
                global_bg_idfa_pid = newPid;
                [self.webView evaluateJavaScript:@"window.onIdfaStateChanged(true);" completionHandler:nil];
            }
        } else if ([body isEqualToString:@"stop_idfa_loop"]) {
            // 浜屾鐐瑰嚮锛氫笅鍙?SIGKILL 鐗╃悊鎴潃鍚庡彴
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
        // 鉁ㄥ叏鏂板挰鍚堬細澶勭悊甯﹀嬀閫夊悕鍗曠殑楂橀樁鍓嶇瀵硅薄 {"action": "xxx", "apps": ["鍖呭悕1", "鍖呭悕2"]}
        NSString *action = body[@"action"];
        
        if ([action isEqualToString:@"start_clean"]) {
            NSArray *apps = body[@"apps"];
            [self executeRootHelperWithMode:@"standard_clean" selectedApps:apps];
        } else if ([action isEqualToString:@"start_realtime_clean"]) {
            NSArray *apps = body[@"apps"];
            pid_t newPid = [self executeRootHelperWithMode:@"realtime_whitelist_clean" selectedApps:apps];
            if (newPid > 0) {
                global_bg_idfa_pid = newPid;
                [self.webView evaluateJavaScript:@"window.onIdfaStateChanged(true);" completionHandler:nil];
            }
        } else if ([action isEqualToString:@"open_url"]) {
            NSString *urlString = body[@"url"];
            if (urlString) {
                NSURL *url = [NSURL URLWithString:urlString];
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        }
    }
}

// 馃殌 鍔ㄦ€佹淳鐢熸彁鏉冭繘绋嬶紙瀹岀編浼犻€掔敤鎴峰嬀閫夌殑搴旂敤鍚嶅崟鍙傛暟 + stdout 绠￠亾瀹炴椂鍥炰紶锛?
- (pid_t)executeRootHelperWithMode:(NSString *)mode selectedApps:(NSArray *)selectedApps {
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"RootHelper" ofType:nil];
    if (!helperPath) return 0;
    
    // 鏋勫缓 C 璇█鏍囧噯鐨?argv 鍔ㄦ€佸弬鏁板垪鏁扮粍
    NSMutableArray *argsArray = [NSMutableArray array];
    [argsArray addObject:helperPath]; // argv[0] 鏄▼搴忚嚜韬矾寰?
    [argsArray addObject:mode];       // argv[1] 鏄繍琛屾ā寮忚建
    
    // 灏嗙敤鎴峰嬀閫夌殑鍚嶅崟杩藉姞鍒?argv[2], argv[3]... 鍚庨潰锛屽疄鐜版暟鎹墿鐞嗗挰鍚?
    if (selectedApps && selectedApps.count > 0) {
        [argsArray addObjectsFromArray:selectedApps];
    }
    
    // 杞负 C 鎸囬拡鍒嗛厤鍐呭瓨
    int argCount = (int)argsArray.count;
    const char **argv = calloc(argCount + 1, sizeof(char *));
    for (int i = 0; i < argCount; i++) {
        argv[i] = [argsArray[i] UTF8String];
    }
    argv[argCount] = NULL; // 缁撴瀯浣撶粨灏惧繀椤荤疆绌?
    
    // 寤虹珛绠￠亾锛屾帴閫?RootHelper 鐨?stdout 瀹炴椂鏃ュ織娴?
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
    close(pipefd[1]); // 鐖惰繘绋嬪叧闂閬撳啓绔?
    
    if (status == 0) {
        NSLog(@"[SPAWN] RootHelper launched with %d targets (PID: %d)", (argCount - 2), pid);
        
        // 寮傛璇诲彇绠￠亾锛屽皢 RootHelper 鐨?stdout 瀹炴椂杞彂鑷冲墠绔?WebView 鏃ュ織闈㈡澘
        int readFd = pipefd[0];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            FILE *stream = fdopen(readFd, "r");
            if (!stream) { close(readFd); return; }
            
            char buffer[1024];
            while (fgets(buffer, sizeof(buffer), stream) != NULL) {
                NSString *line = [[NSString alloc] initWithUTF8String:buffer];
                // 鍘婚櫎琛屽熬鎹㈣
                line = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if (line.length == 0) continue;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 杞箟鍗曞紩鍙烽槻姝?JS 娉ㄥ叆宕╂簝
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 寮哄埗灏?WebView 瑙嗗彛鐣岄檺鐗╃悊鎷変几/閲嶇疆鍒板綋鍓嶅睆骞曠墿鐞嗗ぇ灏忥紝瀹岀編淇鏃嬭浆鏃舵瘮渚嬫病鏈夋敼鍙樸€佸唴瀹规帀鍒板睆骞曞鐨凚ug
    self.webView.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden { return YES; }
@end

// 鈹€鈹€ 鏍囧噯 AppDelegate 澹冲瓙 鈹€鈹€
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
