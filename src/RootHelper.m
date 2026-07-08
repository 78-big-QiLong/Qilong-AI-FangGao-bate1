#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sqlite3.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>
#import <dlfcn.h>
#import <mach/mach.h>

// IOKit types defined manually to avoid iOS SDK availability restrictions
typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
typedef char io_string_t[512];
typedef uint32_t IOOptionBits;

// 0伪装：标准终端真实日志输出，直接对接前端 WebView 日志面板
void printRealLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("[ROOT_HELPER] %s\n", [message UTF8String]);
    fflush(stdout);
}

// ── 辅助工具：posix_spawn 封装 ──
int spawnAndWait(const char *path, const char **argv) {
    pid_t pid;
    int status = posix_spawn(&pid, path, NULL, NULL, (char* const*)argv, NULL);
    if (status == 0) {
        int waitStatus = 0;
        waitpid(pid, &waitStatus, 0);
        return WIFEXITED(waitStatus) ? WEXITSTATUS(waitStatus) : -1;
    }
    return -1;
}

// ── 辅助工具：强杀守护进程（通过进程名） ──
void killDaemonByName(const char *name) {
    const char *args[] = {"/usr/bin/killall", "-9", name, NULL};
    spawnAndWait(args[0], args);
}

// ============================================================================
// IDFA + IDFV 全维度强制刷新（三遍覆写 + 读取回显）
// ============================================================================
void resetIDFAIdentifier() {
    NSString *adPlist = @"/var/mobile/Library/Preferences/com.apple.AdLib.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (int i = 1; i <= 3; i++) {
        NSString *newUUID = [[NSUUID UUID] UUIDString];
        
        // ── 方案A：直接覆写 AdLib plist ──
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:adPlist];
        if (!dict) dict = [NSMutableDictionary dictionary];
        
        [dict setObject:newUUID forKey:@"ADI_DEVICE_IDENTIFIER_DEPRECATED"];
        [dict setObject:newUUID forKey:@"AdvertisingIdentifier"];
        [dict setObject:newUUID forKey:@"IDFA"];
        [dict setObject:@(YES) forKey:@"LimitAdTracking"];
        [dict setObject:@(YES) forKey:@"forceLimitAdTracking"];
        [dict writeToFile:adPlist atomically:YES];
        
        // ── 方案B：通过 MobileGestalt 直接注入（不需要重启） ──
        void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (gestalt) {
            int (*MGSetAnswer)(CFStringRef key, CFTypeRef value) = dlsym(gestalt, "MGSetAnswer");
            if (MGSetAnswer) {
                CFStringRef cfUUID = (__bridge CFStringRef)newUUID;
                MGSetAnswer(CFSTR("UniqueDeviceID"), cfUUID);
                printRealLog(@"[IDFA] Round %d: MobileGestalt injected: %@", i, newUUID);
            }
            dlclose(gestalt);
        }
        
        // ── 方案C：覆写 identifierForAdvertising 底层缓存 plist ──
        NSString *adIdPlist2 = @"/var/mobile/Library/Preferences/com.apple.AdServices.plist";
        NSMutableDictionary *adDict2 = [NSMutableDictionary dictionaryWithContentsOfFile:adIdPlist2];
        if (!adDict2) adDict2 = [NSMutableDictionary dictionary];
        [adDict2 setObject:newUUID forKey:@"adsIdentifier"];
        [adDict2 writeToFile:adIdPlist2 atomically:YES];
        
        // ── 方案D：覆写 identifierForVendor 底层缓存 ──
        NSString *vendorPlist = @"/var/mobile/Library/Preferences/com.apple.identifierForVendor.plist";
        NSString *newVendorUUID = [[NSUUID UUID] UUIDString]; // IDFV 独立生成
        NSMutableDictionary *vendorDict = [NSMutableDictionary dictionaryWithContentsOfFile:vendorPlist];
        if (!vendorDict) vendorDict = [NSMutableDictionary dictionary];
        [vendorDict setObject:newVendorUUID forKey:@"VendorIdentifier"];
        [vendorDict setObject:newVendorUUID forKey:@"IdentifierForVendor"];
        [vendorDict writeToFile:vendorPlist atomically:YES];
        
        // ── 方案E：清除所有 IDFV 相关的 Keychain 条目 ──
        // IDFV 存储在 keychain 中的 com.apple.identifierForVendor
        sqlite3 *db;
        if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
            const char *sql = "DELETE FROM genp WHERE agrp LIKE '%com.apple.identifierForVendor%';";
            char *errMsg = NULL;
            if (sqlite3_exec(db, sql, NULL, NULL, &errMsg) == SQLITE_OK) {
                int changes = sqlite3_changes(db);
                if (changes > 0) {
                    printRealLog(@"[IDFV] Round %d: Purged %d vendor keychain entries.", i, changes);
                }
            }
            if (errMsg) sqlite3_free(errMsg);
            sqlite3_close(db);
        }

        // ── 广播催促系统守护进程同步 ──
        notify_post("com.apple.AdLib.LimitAdTrackingChanged");
        notify_post("com.apple.idfa.changed");
        notify_post("com.apple.identityservicesd.idchanged");
        notify_post("com.apple.MobileGestalt.didChange");
        
        // 反向重读验证
        NSDictionary *verifyDict = [NSDictionary dictionaryWithContentsOfFile:adPlist];
        NSString *currentIDFA = verifyDict[@"AdvertisingIdentifier"] ?: @"READ_FAILED";
        NSDictionary *verifyVendor = [NSDictionary dictionaryWithContentsOfFile:vendorPlist];
        NSString *currentIDFV = verifyVendor[@"VendorIdentifier"] ?: newVendorUUID;
        
        printRealLog(@"[IDFA] Round %d: New IDFA = %@", i, currentIDFA);
        printRealLog(@"[IDFV] Round %d: New IDFV = %@", i, currentIDFV);
    }
    
    // ── 杀死广告守护进程强制立即生效（无需重启） ──
    killDaemonByName("adprivacyd");
    killDaemonByName("adid");
    killDaemonByName("AdServices");
    printRealLog(@"[IDFA] Ad daemons killed. Changes effective immediately.");
}

// ============================================================================
// Keychain 多方案联合清理
// ============================================================================
void deleteSelectedAppKeychain(NSArray *bundleIDs) {
    if (!bundleIDs || bundleIDs.count == 0) {
        printRealLog(@"[KEYCHAIN] No target selected. Skipping.");
        return;
    }
    
    // ── 方案1：SQLite 直接删除 keychain-2.db ──
    printRealLog(@"[KEYCHAIN] Method 1: SQLite direct delete...");
    sqlite3 *db;
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
        for (NSString *bundleID in bundleIDs) {
            if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) {
                printRealLog(@"[SECURITY] Bypassed system domain: %@", bundleID);
                continue;
            }
            
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
                            printRealLog(@"[KEYCHAIN] SQLite %@: Deleted %d records for %@.", table, changes, bundleID);
                        }
                    }
                    sqlite3_finalize(stmt);
                }
            }
        }
        sqlite3_close(db);
    } else {
        printRealLog(@"[ERROR] SQLite: Could not open keychain-2.db");
    }
    
    // ── 方案2：扩展匹配 - 删除包含 bundleID 在 svce/acct/sdmn 列中的条目 ──
    printRealLog(@"[KEYCHAIN] Method 2: Extended column match...");
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
        for (NSString *bundleID in bundleIDs) {
            if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) continue;
            
            NSString *likePattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
            NSArray *tables = @[@"genp", @"inet"];
            
            for (NSString *table in tables) {
                // 匹配 svce (service), acct (account), sdmn (server domain)
                NSArray *columns = @[@"svce", @"acct", @"sdmn"];
                for (NSString *col in columns) {
                    NSString *query = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ LIKE ?;", table, col];
                    sqlite3_stmt *stmt;
                    if (sqlite3_prepare_v2(db, [query UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
                        sqlite3_bind_text(stmt, 1, [likePattern UTF8String], -1, SQLITE_TRANSIENT);
                        if (sqlite3_step(stmt) == SQLITE_DONE) {
                            int changes = sqlite3_changes(db);
                            if (changes > 0) {
                                printRealLog(@"[KEYCHAIN] Extended %@.%@: Deleted %d records.", table, col, changes);
                            }
                        }
                        sqlite3_finalize(stmt);
                    }
                }
            }
        }
        sqlite3_close(db);
    }
    
    // ── 方案3：WAL checkpoint 强制写入 + VACUUM 压缩 ──
    printRealLog(@"[KEYCHAIN] Method 3: WAL checkpoint + VACUUM...");
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
        sqlite3_exec(db, "VACUUM;", NULL, NULL, NULL);
        sqlite3_close(db);
        printRealLog(@"[KEYCHAIN] DB compacted successfully.");
    }
    
    // ── 方案4：删除 keychain WAL/SHM 残留文件 ──
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *keychainAuxFiles = @[
        @"/var/keychains/keychain-2.db-shm",
        @"/var/keychains/keychain-2.db-wal"
    ];
    for (NSString *path in keychainAuxFiles) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
            printRealLog(@"[KEYCHAIN] Removed aux file: %@", [path lastPathComponent]);
        }
    }
    
    // ── 方案5：杀死 securityd 强制立即重载（无需重启） ──
    killDaemonByName("securityd");
    printRealLog(@"[KEYCHAIN] securityd killed. Keychain cache invalidated.");
}

// ============================================================================
// NVRAM 多方案联合清理
// ============================================================================
void clearNVRAMVariables() {
    printRealLog(@"[NVRAM] Starting multi-method erase...");
    
    // ── 方案1：nvram -c 清空所有非硬件锁死变量 ──
    printRealLog(@"[NVRAM] Method 1: nvram -c...");
    {
        const char *args[] = {"/usr/sbin/nvram", "-c", NULL};
        int ret = spawnAndWait(args[0], args);
        if (ret == 0) {
            printRealLog(@"[NVRAM] Method 1: Success.");
        } else {
            printRealLog(@"[NVRAM] Method 1: nvram -c returned %d.", ret);
        }
    }
    
    // ── 方案2：逐一删除已知的追踪相关 NVRAM 变量 ──
    printRealLog(@"[NVRAM] Method 2: Targeted variable delete...");
    NSArray *nvramKeys = @[
        @"auto-boot", @"boot-args", @"SystemAudioVolumeSaved",
        @"bluetoothExternalDongleFailed", @"bluetoothInternalControllerInfo",
        @"fmm-computer-name", @"prev-lang:kbd", @"LocationServicesEnabled",
        @"com.apple.System.boot-nonce", @"USBPortAssignment"
    ];
    for (NSString *key in nvramKeys) {
        NSString *deleteArg = [NSString stringWithFormat:@"-d"];
        const char *args[] = {"/usr/sbin/nvram", "-d", [key UTF8String], NULL};
        spawnAndWait(args[0], args);
    }
    printRealLog(@"[NVRAM] Method 2: Targeted keys purged.");
    
    // ── 方案3：通过 dlsym 动态加载 IOKit 操作 NVRAM（绕过 iOS SDK 限制） ──
    printRealLog(@"[NVRAM] Method 3: IOKit dynamic manipulation...");
    void *iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokitHandle) {
        typedef io_registry_entry_t (*IORegEntryFromPathFunc)(mach_port_t, const io_string_t);
        typedef kern_return_t (*IORegEntryCreateCFPropsFunc)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits);
        typedef kern_return_t (*IORegEntrySetCFPropFunc)(io_registry_entry_t, CFStringRef, CFTypeRef);
        typedef kern_return_t (*IOObjectReleaseFunc)(io_object_t);
        
        IORegEntryFromPathFunc myIORegFromPath = dlsym(iokitHandle, "IORegistryEntryFromPath");
        IORegEntryCreateCFPropsFunc myIORegCreateCFProps = dlsym(iokitHandle, "IORegistryEntryCreateCFProperties");
        IORegEntrySetCFPropFunc myIORegSetCFProp = dlsym(iokitHandle, "IORegistryEntrySetCFProperty");
        IOObjectReleaseFunc myIOObjectRelease = dlsym(iokitHandle, "IOObjectRelease");
        
        if (myIORegFromPath && myIORegCreateCFProps && myIORegSetCFProp && myIOObjectRelease) {
            io_registry_entry_t nvram = myIORegFromPath(MACH_PORT_NULL, "IODeviceTree:/options");
            if (nvram != MACH_PORT_NULL) {
                CFMutableDictionaryRef properties = NULL;
                if (myIORegCreateCFProps(nvram, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
                    NSDictionary *nvramDict = (__bridge NSDictionary *)properties;
                    int deletedCount = 0;
                    for (NSString *key in nvramDict.allKeys) {
                        if ([key hasPrefix:@"40A0DDD2"] || [key hasPrefix:@"8BE4DF61"]) continue;
                        if ([key isEqualToString:@"IORegistryEntryPropertyKeys"]) continue;
                        
                        kern_return_t result = myIORegSetCFProp(nvram, (__bridge CFStringRef)key, CFSTR(""));
                        if (result == KERN_SUCCESS) {
                            deletedCount++;
                        }
                    }
                    CFRelease(properties);
                    printRealLog(@"[NVRAM] Method 3: Cleared %d IOKit variables.", deletedCount);
                }
                myIOObjectRelease(nvram);
            } else {
                printRealLog(@"[NVRAM] Method 3: IOKit NVRAM not accessible.");
            }
        } else {
            printRealLog(@"[NVRAM] Method 3: IOKit symbols not resolved.");
        }
        dlclose(iokitHandle);
    } else {
        printRealLog(@"[NVRAM] Method 3: IOKit framework not loaded.");
    }
    
    // ── 方案4：删除 NVRAM 持久化缓存文件 ──
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *nvramCacheFiles = @[
        @"/var/mobile/Library/Preferences/com.apple.purplebuddy.plist",
        @"/var/mobile/Library/Preferences/.GlobalPreferences.plist",
        @"/var/root/Library/Preferences/com.apple.purplebuddy.plist"
    ];
    for (NSString *path in nvramCacheFiles) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
            printRealLog(@"[NVRAM] Removed cache file: %@", [path lastPathComponent]);
        }
    }
    
    printRealLog(@"[NVRAM] Multi-method erase complete.");
}

// ============================================================================
// Clean shared and plugin containers matching bundle IDs
// ============================================================================
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

// 安全红线滤网：深度递归清理自定义 var 目录
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

    // 判断当前目录是否属于"公共纯缓存丢弃区"
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

        // 铁律红线一：大文件强行熔断锁 (>100MB 资产直接放行)
        unsigned long long fileSize = [attrs fileSize];
        if (fileSize > 100 * 1024 * 1024) { 
            printRealLog(@"[LIMIT] Skipped large file (>100MB): %@ (%llu MB)", fileName, fileSize / 1024 / 1024);
            continue;
        }

        BOOL isSubDir = [attrs.fileType isEqualToString:NSFileTypeDirectory];

        if (isSubDir) {
            safeCleanDirectory(fullPath, targetBundleIDs);
        } else {
            BOOL deleteAllowed = NO;
            
            if (isPureCacheZone) {
                deleteAllowed = YES;
            } else {
                for (NSString *bundleID in targetBundleIDs) {
                    if ([fileName containsString:bundleID]) {
                        deleteAllowed = YES;
                        break;
                    }
                }
            }

            if (deleteAllowed) {
                NSError *deleteError = nil;
                if ([fm removeItemAtPath:fullPath error:&deleteError]) {
                    printRealLog(@"[CLEAN] Removed file: %@", fileName);
                } else if (deleteError) {
                    printRealLog(@"[ERROR] Permission denied: %@. Reason: %@", fileName, deleteError.localizedDescription);
                }
            }
        }
    }
    
    // 连根拔除：递归清理完毕后，若当前目录已成空壳则物理拔除
    NSArray *remaining = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (remaining && remaining.count == 0) {
        NSError *rmDirErr = nil;
        if ([fm removeItemAtPath:dirPath error:&rmDirErr]) {
            printRealLog(@"[CLEAN] Removed empty dir: %@", dirPath);
        }
    }
}

// ============================================================================
// 无需重启的守护进程重载方案
// ============================================================================
void forceRefreshWithoutReboot() {
    printRealLog(@"[REFRESH] Killing daemons to force immediate effect (no reboot)...");
    
    // 杀死广告相关守护进程
    killDaemonByName("adprivacyd");
    killDaemonByName("adid");
    
    // 杀死 keychain 守护进程
    killDaemonByName("securityd");
    
    // 杀死 cfprefsd 刷新 plist 缓存
    killDaemonByName("cfprefsd");
    
    // 杀死 nfcd（NFC 指纹相关）
    killDaemonByName("nfcd");
    
    // 杀死后台分析守护进程
    killDaemonByName("analyticsd");
    killDaemonByName("diagnosticd");
    
    // 发射全维度系统广播催促刷新
    notify_post("com.apple.AdLib.LimitAdTrackingChanged");
    notify_post("com.apple.idfa.changed");
    notify_post("com.apple.identityservicesd.idchanged");
    notify_post("com.apple.MobileGestalt.didChange");
    notify_post("com.apple.pasteboard.changed");
    notify_post("com.apple.system.config.network_change");
    notify_post("com.apple.springboard.finishedstartup");
    
    printRealLog(@"[REFRESH] All daemons killed + broadcasts sent. Effect immediate.");
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
            
            pid_t parentPid = getppid();
            int round = 1;
            
            while (1) {
                // 【Watchdog卡点 A】父进程变为 1 或被杀
                if (getppid() == 1 || kill(parentPid, 0) != 0) {
                    printRealLog(@"[DAEMON] Parent process killed. Exiting.");
                    break;
                }
                
                printRealLog(@"[DAEMON] Round %d: Overwriting IDFA+IDFV...", round);
                resetIDFAIdentifier();
                
                // 每轮刷新后立即杀死守护进程使其生效
                forceRefreshWithoutReboot();
                
                printRealLog(@"[DAEMON] Round %d complete. Waiting 60s.", round);
                
                round++;
                
                // 60秒切碎为60次1秒试探
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
            
            // 1. 强制覆写三遍随机 UUID（IDFA + IDFV）
            resetIDFAIdentifier();
            printRealLog(@"[IDFA] Multi-method IDFA+IDFV refresh complete.");
            
            // 2. 多方案清除 NVRAM
            clearNVRAMVariables();
            
            // 3. 多方案联合 Keychain 清理
            deleteSelectedAppKeychain(selectedAppBundleIDs);
            
            // 3.5 清理 Safari 的全局 Cookie、网页状态及 WebKit 跨进程缓存
            cleanSafariAndWebKit();
            
            // 3.6 物理抹除剪贴簿缓存并同步发射广播
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.apple.Pasteboard" error:nil];
            notify_post("com.apple.pasteboard.changed");
            printRealLog(@"[CLEAN] Clipboard cache erased.");
            
            // 3.7 清洗共享特权目录
            cleanSpecialContainers(@"/var/mobile/Containers/Shared/AppGroup", selectedAppBundleIDs);
            cleanSpecialContainers(@"/var/mobile/Containers/Data/PluginKitPlugin", selectedAppBundleIDs);
            
            // 4. 横扫自定义硬核重灾路径
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
            
            // 5. 先执行无重启方案强制立即生效
            forceRefreshWithoutReboot();
            
            // 6. 最终重启用户空间刷新全机进程缓存
            triggerUserspaceReboot();
        }
    }
    return 0;
}
