#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "DeviceInfo.h"
#import <spawn.h>
#import <signal.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) WKWebView *webView;
@end

@implementation AppDelegate

static pid_t global_bg_idfa_pid = 0;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.userContentController addScriptMessageHandler:self name:@"trollAction"];
    
    self.webView = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:config];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = self.webView;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    
    // 🚀【路徑更名】精確指引 UI 網頁加載至全新的 QiLong-Dynamic-Whitelist.app 內
    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html" inDirectory:@"QiLong-Dynamic-Whitelist.app"];
    if (!htmlPath) htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    
    if (htmlPath) {
        [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL fileURLWithPath:htmlPath]]];
    } else {
        [self.webView loadHTMLString:@"<h1 style='color:white;text-align:center;'>QiLong Shield UI Asset Missing</h1>" baseURL:nil];
    }
    
    return YES;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"trollAction"]) {
        NSDictionary *body = message.body;
        NSString *action = body[@"action"];
        NSArray *apps = body[@"apps"] ? body[@"apps"] : @[];
        
        if ([action isEqualToString:@"executeClean"]) {
            [self launchRootHelperWithMode:@"standard_clean" bundles:apps];
        } else if ([action isEqualToString:@"startIDFA"]) {
            [self launchRootHelperWithMode:@"bg_idfa_loop" bundles:@[]];
        } else if ([action isEqualToString:@"stopIDFA"]) {
            if (global_bg_idfa_pid > 0) {
                if (kill(global_bg_idfa_pid, SIGKILL) == 0) {
                    printf("[MAIN_UI] 成功向守護進程 (PID: %d) 發射 SIGKILL，無線快刷已終止！\n", global_bg_idfa_pid);
                }
                global_bg_idfa_pid = 0;
            }
        }
    }
}

- (void)launchRootHelperWithMode:(NSString *)mode bundles:(NSArray *)bundles {
    // 🚀【路徑更名】精確指引巨魔提權二進制路徑至全新的 QiLong-Dynamic-Whitelist.app 內
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"RootHelper" ofType:nil inDirectory:@"QiLong-Dynamic-Whitelist.app"];
    if (!helperPath) helperPath = [[NSBundle mainBundle] pathForResource:@"RootHelper" ofType:nil];
    
    if (!helperPath) {
        printf("[MAIN_UI 嚴重錯誤] 找不到後端 RootHelper 執行檔案！\n");
        return;
    }
    
    if ([mode isEqualToString:@"bg_idfa_loop"] && global_bg_idfa_pid > 0) {
        kill(global_bg_idfa_pid, SIGKILL);
        global_bg_idfa_pid = 0;
    }

    pid_t pid;
    int argc = (int)bundles.count + 2;
    const char **argv = malloc(sizeof(char *) * (argc + 1));
    argv[0] = [helperPath UTF8String];
    argv[1] = [mode UTF8String];
    
    for (int i = 0; i < bundles.count; i++) {
        argv[i + 2] = [bundles[i] UTF8String];
    }
    argv[argc] = NULL;
    
    int spawnStatus = posix_spawn(&pid, argv[0], NULL, NULL, (char* const*)argv, NULL);
    free(argv);
    
    if (spawnStatus == 0) {
        if ([mode isEqualToString:@"bg_idfa_loop"]) {
            global_bg_idfa_pid = pid;
            printf("[MAIN_UI] 後台 IDFA 快刷守護進程掛載成功！PID: %d\n", pid);
        }
    }
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}