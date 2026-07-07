#import <Foundation/Foundation.h>
#import <posix_spawn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <wait.h>
#import <sqlite3.h>
#import <notify.h>   
#import <signal.h>   
#import <unistd.h>

// 0伪装：标准终端真实日志输出，直接对接前端 WebView 日志面板
void printRealLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("[ROOT_HELPER] %s\n", [message UTF8String]);
    fflush(stdout);
}

// 强制执行三遍物理级 IDFA 全空白 "" 覆写并向系统发射全局催促广播
void resetIDFAIdentifier() {
    NSString *adPlist = @"/var/mobile/Library/Preferences/com.apple.AdLib.plist";
    
    for (int i = 1; i <= 3; i++) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:adPlist];
        if (!dict) dict = [NSMutableDictionary dictionary];
        
        // 铁律：100% 改写为空白内容 "" 强制覆写残留缓存
        [dict setObject:@"" forKey:@"ADI_DEVICE_IDENTIFIER_DEPRECATED"];
        [dict setObject:@"" forKey:@"AdvertisingIdentifier"];
        [dict setObject:@(YES) forKey:@"LimitAdTracking"]; // 固化锁死限制广告追踪
        
        [dict writeToFile:adPlist atomically:YES];
    }
    
    // 发射双重大地形全局广播，逼迫系统 adprivacyd 守护进程瞬间向全白底座看齐
    notify_post("com.apple.AdLib.LimitAdTrackingChanged");
    notify_post("com.apple.idfa.changed");
}

// 清空自定义 NVRAM 环境变量
void clearNVRAMVariables() {
    printRealLog(@"[内核] 正在执行 NVRAM 自定义变量擦除...");
    pid_t pid;
    const char *args[] = {"/usr/sbin/nvram", "-c", NULL}; // -c 清空所有非硬件锁死变量
    int status = posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    if (status == 0) {
        waitid(P_PID, pid, NULL, WEXITED);
        printRealLog(@"[成功] 自定义 NVRAM 变量已全部擦除。");
    }
}

// SQLite3 跨沙盒物理爆破名单中所选应用的所有钥匙链（Keychain）
void deleteSelectedAppKeychain(NSArray *bundleIDs) {
    if (!bundleIDs || bundleIDs.count == 0) {
        printRealLog(@"[钥匙串] 未勾选任何名单，跳过钥匙链清洗。");
        return;
    }
    
    sqlite3 *db;
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) != SQLITE_OK) {
        printRealLog(@"[严重错误] 钥匙串数据库拒绝连接，请确认巨魔提权环境。");
        return;
    }
    
    for (NSString *bundleID in bundleIDs) {
        if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) {
            printRealLog(@"[安全拦截] 钥匙链拒绝触碰系统核心域: %@", bundleID);
            continue;
        }
        
        printRealLog(@"[钥匙串] 正在定点清洗匹配链: %@", bundleID);
        NSString *likePattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
        NSArray *tables = @[@"genp", @"inet", @"keys", @"cert"];
        
        for (NSString *table in tables) {
            NSString *query = [NSString stringWithFormat:@"DELETE FROM %@ WHERE agrp LIKE ?;", table];
            sqlite3_stmt *stmt;
            
            if (sqlite3_prepare_v2(db, [query UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, [likePattern UTF8String], -1, SQLITE_TRANSIENT);
                if (sqlite3_step(stmt) == SQLITE_DONE) {
                    int changes = sqlite3_changes(db);
                    if (changes > 0) {
                        printRealLog(@"[移除] 表 %@ 成功蒸发 %d 条残留凭证。", table, changes);
                    }
                }
                sqlite3_finalize(stmt);
            }
        }
    }
    sqlite3_close(db);
}

// 安全红线滤网：深度递归清理 27 个自定义 var 目录
void safeCleanDirectory(NSString *dirPath, NSArray *targetBundleIDs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir]) return;

    // 顶级避让：绝对禁止物理抹除用户层与系统底层基石目录本身
    if ([dirPath isEqualToString:@"/var"] || [dirPath isEqualToString:@"/var/mobile"] || [dirPath isEqualToString:@"/var/root"] || [dirPath isEqualToString:@"/var/containers/Bundle"]) {
        return;
    }

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error) return;

    // 判断当前目录是否属于“公共纯缓存丢弃区”（如 logs, tmp, Caches 目录）
    NSString *lowerPath = [dirPath lowercaseString];
    BOOL isPureCacheZone = [lowerPath containsString:@"/caches"] || 
                           [lowerPath containsString:@"/log"] || 
                           [lowerPath containsString:@"/tmp"] || 
                           [lowerPath containsString:@"/cookies"] ||
                           [lowerPath containsString:@"/webkit"];

    for (NSString *fileName in files) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:fileName];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        if (!attrs) continue;

        // 铁律红线一：大文件强行熔断锁 (>100MB 资产直接放行，不损坏大包)
        unsigned longLong fileSize = [attrs fileSize];
        if (fileSize > 100 * 1024 * 1024) { 
            printRealLog(@"[保护熔断] 拦截到超大资产文件, 已跳过: %@ (%llu MB)", fileName, fileSize / 1024 / 1024);
            continue;
        }

        BOOL isSubDir = [attrs.fileType isEqualToString:NSFileTypeDirectory];

        if (isSubDir) {
            // 如果是子目录，向下递归深度巡检
            safeCleanDirectory(fullPath, targetBundleIDs);
        } else {
            // 执行原子减法清理策略
            BOOL deleteAllowed = NO;
            
            if (isPureCacheZone) {
                // 情况 A：属于纯缓存/临时日志区，在 <100MB 限制下允许直接抹除
                deleteAllowed = YES;
            } else {
                // 情况 B：属于 Preferences / Application Support 等核心敏感区
                // 必须在文件名中模糊匹配到用户勾选的 App 包名，才允许定点爆破，严防全盘崩溃
                for (NSString *bundleID in targetBundleIDs) {
                    if ([fileName containsString:bundleID]) {
                        deleteAllowed = YES;
                        break;
                    }
                }
            }

            if (deleteAllowed) {
                // 铁律红线二：对目标 App 文件夹只做删除（减法），绝不注入 any 伪装补丁或 .pak 文件
                NSError *deleteError = nil;
                [fm removeItemAtPath:fullPath error:&deleteError];
                if (!deleteError) {
                    NSLog(@"[物理清除] 已干掉残留文件: %@", fileName);
                }
            }
        }
    }
}

// 终极再生：安全重启用户空间
void triggerUserspaceReboot() {
    printRealLog(@"[内核] 重置大合拢完成。正在强制安全重启用户空间...");
    pid_t pid;
    const char *args[] = {"/bin/launchctl", "reboot", "userspace", NULL};
    int status = posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    if (status == 0) {
        waitid(P_PID, pid, NULL, WEXITED);
    }
}

// ── 提权辅助器核心多轨总调度入口 ──
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 参数越界防错
        if (argc < 2) {
            printRealLog(@"[错误] 提权总线通信参数缺失。");
            return 1;
        }

        // 解析从 main.m 路由过来的运行轨模式暗号
        NSString *runMode = [NSString stringWithUTF8String:argv[1]];
        
        // 动态咬合：提取并组装用户真正勾选的全部目标应用 Bundle ID 名单
        NSMutableArray *selectedAppBundleIDs = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [selectedAppBundleIDs addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        // ==================== 轨道一：【无线轮询自毁快刷轨】 ====================
        if ([runMode isEqualToString:@"bg_idfa_loop"]) {
            printRealLog(@"[守护] 成功激活后台无限轮询快刷轨（免重启模式）。");
            
            pid_t parentPid = getppid(); // 咬死当前拉起它的前端主 App PID
            int round = 1;
            
            while (1) {
                // 【Watchdog卡点 A】如果父进程变为 1 (被launchd接管) 或主 App 被用户上划清除，1秒内瞬间物理自毁
                if (getppid() == 1 || kill(parentPid, 0) != 0) {
                    printRealLog(@"[自毁] 检测到主App卡片已被划退，后台提权守护优雅退出，0残留。");
                    break;
                }
                
                printRealLog(@"[后台定点爆发] 第 %d 轮：正在强制空刷3遍 IDFA 并广播...", round);
                resetIDFAIdentifier();
                printRealLog(@"[成功] 第 %d 轮数据固化已完成。进入下一分钟挂机等待。", round);
                
                round++;
                
                // 【Watchdog卡点 B】将 60 秒睡眠精细切碎为 60 次 1 秒试探
                // 确保用户只要在任意时间点划掉后台，进程在 1 秒内做出响应并执行物理毁灭
                for (int i = 0; i < 60; i++) {
                    sleep(1);
                    if (getppid() == 1 || kill(parentPid, 0) != 0) {
                        printRealLog(@"[自毁] 挂机中途捕获主App自毁信号，立即退出。");
                        exit(0);
                    }
                }
            }
            return 0;
        }
        
        // ==================== 轨道二：【重度深清空间轨】 ====================
        if ([runMode isEqualToString:@"standard_clean"]) {
            printRealLog(@"[提权] 成功激活重度深清轨（联动重启用户空间）。");
            printRealLog(@"[当前勾选清洗目标数]: %lu 个", (unsigned long)selectedAppBundleIDs.count);
            
            // 1. 强制覆写三遍全空白广告底座
            resetIDFAIdentifier();
            printRealLog(@"[完成] 全白广告指纹库覆写完毕。");
            
            // 2. 清除 NVRAM 标记
            clearNVRAMVariables();
            
            // 3. SQLite3 物理爆破所选应用在系统库中的 Keychain 痕迹
            deleteSelectedAppKeychain(selectedAppBundleIDs);
            
            // 4. 横扫 27 个 var 自定义硬核重灾路径
            NSArray *customVarPaths = @[
                @"/var", @"/var/containers", @"/var/containers/Bundle",
                @"/var/db/com.apple.xpc.roleaccountd.staging", @"/var/log", @"/var/mobile",
                @"/var/mobile/Documents", @"/var/mobile/Library",
                @"/var/mobile/Library/Application Support",
                @"/var/mobile/Library/Application Support/Containers",
                @"/var/mobile/Library/Caches", @"/var/mobile/Library/Cookies",
                @"/var/mobile/Library/HTTPStorages", @"/var/mobile/Library/Logs",
                @"/var/mobile/Library/Preferences", @"/var/mobile/Library/Saved Application State",
                @"/var/mobile/Library/SplashBoard/Snapshots",
                @"/var/mobile/Library/UserConfigurationProfiles/PublicInfo/",
                @"/var/mobile/Library/WebKit", @"/var/mobile/Media", @"/var/root",
                @"/var/root/Library", @"/var/root/Library/Application Support",
                @"/var/root/Library/Caches", @"/var/root/Library/HTTPStorages",
                @"/var/root/Library/Preferences", @"/var/root/Library/Tmp"
            ];
            
            printRealLog(@"[清洗] 正在横扫 27 个 var 规则库战场...");
            for (NSString *path in customVarPaths) {
                safeCleanDirectory(path, selectedAppBundleIDs);
            }
            printRealLog(@"[成功] var 自定义规则库文件定点减法清理完毕。");
            
            // 5. 最终甩出终极杀招，重启用户空间刷新全机进程缓存
            triggerUserspaceReboot();
        }
    }
    return 0;
}