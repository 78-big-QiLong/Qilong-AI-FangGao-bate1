#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <sys/wait.h> // ✅ 加上 sys/ 前缀，iOS 底层标准正确路径
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

// 强制执行三遍物理级 IDFA 随机 UUID 覆写并向系统发射全局催促广播，每遍单独发送广播并读取回显
void resetIDFAIdentifier() {
    NSString *adPlist = @"/var/mobile/Library/Preferences/com.apple.AdLib.plist";
    
    for (int i = 1; i <= 3; i++) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:adPlist];
        if (!dict) dict = [NSMutableDictionary dictionary];
        
        // 铁律：每遍动态生成全新随机 UUID 指纹覆写，拒绝空字符串装盲
        NSString *newUUID = [[NSUUID UUID] UUIDString];
        [dict setObject:newUUID forKey:@"ADI_DEVICE_IDENTIFIER_DEPRECATED"];
        [dict setObject:newUUID forKey:@"AdvertisingIdentifier"];
        [dict setObject:@(YES) forKey:@"LimitAdTracking"]; // 固化锁死限制广告追踪
        
        [dict writeToFile:adPlist atomically:YES];
        
        // 发射双重大地形全局广播，逼迫系统 adprivacyd 守护进程瞬间同步
        notify_post("com.apple.AdLib.LimitAdTrackingChanged");
        notify_post("com.apple.idfa.changed");
        
        // 反向重读验证：读取 plist 中固化的最新 IDFA 值并回显
        NSDictionary *verifyDict = [NSDictionary dictionaryWithContentsOfFile:adPlist];
        NSString *currentIDFA = verifyDict[@"AdvertisingIdentifier"] ?: @"这里是读取失败时的默认值";
        printRealLog(@"[IDFA] 任务随机刷新第 %d 次，当前干净标识符已变更为: %@", i, currentIDFA);
    }
}

// Clean shared and plugin containers matching bundle IDs
void cleanSpecialContainers(NSString *containersRoot, NSArray *targetBundleIDs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:containersRoot error:&error];
    if (error) return;
    
    for (NSString *fileName in files) {
        NSString *fullPath = [containersRoot stringByAppendingPathComponent:fileName];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
            NSString *metadataPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            if ([fm fileExistsAtPath:metadataPath]) {
                NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                NSString *identifier = metadata[@"MCMMetadataIdentifier"];
                if (identifier) {
                    for (NSString *bundleID in targetBundleIDs) {
                        if ([identifier containsString:bundleID]) {
                            NSError *deleteError = nil;
                            if ([fm removeItemAtPath:fullPath error:&deleteError]) {
                                printRealLog(@"[CLEAN] Removed container: %@", identifier);
                            } else {
                                printRealLog(@"[ERROR] Failed to remove container: %@. Reason: %@", identifier, deleteError.localizedDescription);
                            }
                            break;
                        }
                    }
                }
            }
        }
    }
}

// Clean Safari cookies/history and WebKit web cache
void cleanSafariAndWebKit() {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSString *safariDir = @"/var/mobile/Library/Safari";
    NSArray *safariItems = @[
        [safariDir stringByAppendingPathComponent:@"LocalStorage"],
        [safariDir stringByAppendingPathComponent:@"History.db"],
        [safariDir stringByAppendingPathComponent:@"History.db-shm"],
        [safariDir stringByAppendingPathComponent:@"History.db-wal"],
        [safariDir stringByAppendingPathComponent:@"Cookies.binarycookies"]
    ];
    
    for (NSString *path in safariItems) {
        if ([fm fileExistsAtPath:path]) {
            NSError *err = nil;
            if ([fm removeItemAtPath:path error:&err]) {
                printRealLog(@"[CLEAN] Removed Safari item: %@", [path lastPathComponent]);
            } else {
                printRealLog(@"[ERROR] Failed to remove Safari item: %@. Reason: %@", [path lastPathComponent], err.localizedDescription);
            }
        }
    }
    
    NSString *webKitDir = @"/var/mobile/Library/WebKit";
    if ([fm fileExistsAtPath:webKitDir]) {
        NSError *err = nil;
        if ([fm removeItemAtPath:webKitDir error:&err]) {
            printRealLog(@"[CLEAN] Removed WebKit cache directory");
        } else {
            printRealLog(@"[ERROR] Failed to remove WebKit cache. Reason: %@", err.localizedDescription);
        }
    }
}

// 清空自定义 NVRAM 环境变量
void clearNVRAMVariables() {
    printRealLog(@"[NVRAM] Erasing variables...");
    pid_t pid;
    const char *args[] = {"/usr/sbin/nvram", "-c", NULL}; // -c 清空所有非硬件锁死变量
    int status = posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    if (status == 0) {
        waitid(P_PID, pid, NULL, WEXITED);
        printRealLog(@"[NVRAM] Erased successfully.");
    }
}

// SQLite3 跨沙盒物理爆破名单中所选应用的所有钥匙链（Keychain）
void deleteSelectedAppKeychain(NSArray *bundleIDs) {
    if (!bundleIDs || bundleIDs.count == 0) {
        printRealLog(@"[KEYCHAIN] No target selected. Skipping.");
        return;
    }
    
    sqlite3 *db;
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) != SQLITE_OK) {
        printRealLog(@"[ERROR] Connection failed: Keychain DB.");
        return;
    }
    
    for (NSString *bundleID in bundleIDs) {
        if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) {
            printRealLog(@"[SECURITY] Bypassed system domain: %@", bundleID);
            continue;
        }
        
        printRealLog(@"[KEYCHAIN] Cleaning match: %@", bundleID);
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
                        printRealLog(@"[KEYCHAIN] Table %@: Deleted %d records.", table, changes);
                    }
                } else {
                    printRealLog(@"[ERROR] Table %@ failed: %s", table, sqlite3_errmsg(db));
                }
                sqlite3_finalize(stmt);
            } else {
                printRealLog(@"[ERROR] Table %@ prepare failed: %s", table, sqlite3_errmsg(db));
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

    // 判断当前目录是否属于"公共纯缓存丢弃区"（如 logs, tmp, Caches 目录）
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
        // ✅ 已完美校准为 C 语言标准关键字：unsigned long long
        unsigned long long fileSize = [attrs fileSize];
        if (fileSize > 100 * 1024 * 1024) { 
            printRealLog(@"[LIMIT] Skipped large file (>100MB): %@ (%llu MB)", fileName, fileSize / 1024 / 1024);
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
                if ([fm removeItemAtPath:fullPath error:&deleteError]) {
                    printRealLog(@"[CLEAN] Removed file: %@", fileName);
                } else if (deleteError) {
                    printRealLog(@"[ERROR] Permission denied: %@. Reason: %@", fileName, deleteError.localizedDescription);
                }
            }
        }
    }
    
    // 连根拔除：递归清理完毕后，若当前目录已成空壳则物理拔除目录结构尸体
    NSArray *remaining = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (remaining && remaining.count == 0) {
        NSError *rmDirErr = nil;
        if ([fm removeItemAtPath:dirPath error:&rmDirErr]) {
            printRealLog(@"[CLEAN] Removed empty dir: %@", dirPath);
        }
    }
}

// 终极再生：安全重启用户空间
void triggerUserspaceReboot() {
    printRealLog(@"[KERNEL] Cleaning complete. Triggering userspace reboot...");
    pid_t pid;
    const char *args[] = {"/bin/launchctl", "reboot", "userspace", NULL};
    int status = posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    if (status == 0) {
        printRealLog(@"[KERNEL] Reboot helper spawned (PID: %d).", pid);
        int waitStatus = 0;
        waitpid(pid, &waitStatus, 0);
        if (WIFEXITED(waitStatus)) {
            printRealLog(@"[KERNEL] Reboot helper exited with status: %d.", WEXITSTATUS(waitStatus));
        }
    }
}

// ── 提权辅助器核心多轨总调度入口 ──
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 参数越界防错
        if (argc < 2) {
            printRealLog(@"[ERROR] Missing required arguments.");
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
            printRealLog(@"[DAEMON] Background loop active.");
            
            pid_t parentPid = getppid(); // 咬死当前拉起它的前端主 App PID
            int round = 1;
            
            while (1) {
                // 【Watchdog卡点 A】如果父进程变为 1 (被launchd接管) 或主 App 被用户上划清除，1秒内瞬间物理自毁
                if (getppid() == 1 || kill(parentPid, 0) != 0) {
                    printRealLog(@"[DAEMON] Parent process killed. Exiting.");
                    break;
                }
                
                printRealLog(@"[DAEMON] Round %d: Overwriting IDFA...", round);
                resetIDFAIdentifier();
                printRealLog(@"[DAEMON] Round %d complete. Waiting 60s.", round);
                
                round++;
                
                // 【Watchdog卡点 B】将 60 秒睡眠精细切碎为 60 次 1秒试探
                // 确保用户只要在任意时间点划掉后台，进程在 1 秒内做出响应并执行物理毁灭
                for (int i = 0; i < 60; i++) {
                    sleep(1);
                    if (getppid() == 1 || kill(parentPid, 0) != 0) {
                        printRealLog(@"[DAEMON] Interrupted by parent. Exiting.");
                        exit(0);
                    }
                }
            }
            return 0;
        }
        
        // ==================== 轨道二：【重度深清空间轨】 ====================
        if ([runMode isEqualToString:@"standard_clean"]) {
            printRealLog(@"[KERNEL] Active: Deep clean mode.");
            printRealLog(@"[KERNEL] Target count: %lu", (unsigned long)selectedAppBundleIDs.count);
            
            // 1. 强制覆写三遍随机 UUID 广告底座
            resetIDFAIdentifier();
            printRealLog(@"[IDFA] Random UUID updated.");
            
            // 2. 清除 NVRAM 标记
            clearNVRAMVariables();
            
            // 3. SQLite3 物理爆破所选应用在系统库中的 Keychain 痕迹
            deleteSelectedAppKeychain(selectedAppBundleIDs);
            
            // 3.5 清理 Safari 的全局 Cookie、网页状态及 WebKit 跨进程缓存
            cleanSafariAndWebKit();
            
            // 3.6 物理抹除剪贴簿缓存并同步发射广播
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.apple.Pasteboard" error:nil];
            notify_post("com.apple.pasteboard.changed");
            printRealLog(@"[CLEAN] Clipboard cache erased.");
            
            // 3.7 清洗共享特权目录中匹配的目标应用 AppGroup 与 PluginKitPlugin 容器
            cleanSpecialContainers(@"/var/mobile/Containers/Shared/AppGroup", selectedAppBundleIDs);
            cleanSpecialContainers(@"/var/mobile/Containers/Data/PluginKitPlugin", selectedAppBundleIDs);
            
            // 4. 横扫 27 + 2 个 var 自定义硬核重灾路径
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
                @"/var/root/Library/Preferences", @"/var/root/Library/Tmp",
                @"/var/mobile/Containers/Shared/AppGroup",
                @"/var/mobile/Containers/Data/PluginKitPlugin"
            ];
            
            printRealLog(@"[CLEAN] Scanning paths...");
            for (NSString *path in customVarPaths) {
                safeCleanDirectory(path, selectedAppBundleIDs);
            }
            printRealLog(@"[CLEAN] Completed successfully.");
            
            // 5. 最终甩出终极杀招，重启用户空间刷新全机进程缓存
            triggerUserspaceReboot();
        }
    }
    return 0;
}
