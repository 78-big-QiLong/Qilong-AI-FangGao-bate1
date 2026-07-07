#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <sys/wait.h> 
#import <sqlite3.h>
#import <notify.h>   
#import <signal.h>   
#import <unistd.h>

// 0偽裝：標準終端真實日誌輸出，直接對接前端 WebView 日誌面板
void printRealLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("[ROOT_HELPER] %s\n", [message UTF8String]);
    fflush(stdout);
}

// 物理級 IDFA 動態生成全新隨機 UUID 覆寫，並實時反向讀取校驗回顯
void resetIDFAIdentifier() {
    NSString *adPlist = @"/var/mobile/Library/Preferences/com.apple.AdLib.plist";
    
    // 🚀 【核心升級】生成標準動態隨機指紋 UUID，拒絕無數值空殼
    NSString *newUUID = [[NSUUID UUID] UUIDString];
    
    for (int i = 1; i <= 3; i++) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:adPlist];
        if (!dict) dict = [NSMutableDictionary dictionary];
        
        [dict setObject:newUUID forKey:@"ADI_DEVICE_IDENTIFIER_DEPRECATED"];
        [dict setObject:newUUID forKey:@"AdvertisingIdentifier"];
        [dict setObject:@(YES) forKey:@"LimitAdTracking"]; // 固化鎖死限制廣告追蹤
        
        [dict writeToFile:adPlist atomically:YES];
    }
    
    // 發射雙重大地形全局廣播，逼迫系統守護進程向新底座看齊
    notify_post("com.apple.AdLib.LimitAdTrackingChanged");
    notify_post("com.apple.idfa.changed");
    
    // 🚀 【核心升級】實時反向重讀取，把刷新後的真實 IDFA 指紋打在公屏上！
    NSMutableDictionary *verifyDict = [NSMutableDictionary dictionaryWithContentsOfFile:adPlist];
    NSString *currentIDFA = verifyDict[@"AdvertisingIdentifier"];
    printRealLog(@"[IDFA同步成功] 當前底層文件已固化指紋: [%@]", currentIDFA);
}

// 清空自定義 NVRAM 環境變量
void clearNVRAMVariables() {
    printRealLog(@"[內核] 正在執行 NVRAM 自定義變量擦除...");
    pid_t pid;
    const char *args[] = {"/usr/sbin/nvram", "-c", NULL}; 
    int status = posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    if (status == 0) {
        int waitStatus = 0;
        waitpid(pid, &waitStatus, 0);
        printRealLog(@"[成功] 自定義 NVRAM 變量已擦除，進程退出碼: %d", waitStatus);
    } else {
        printRealLog(@"[錯誤] NVRAM 變量擦除進程派生失敗，狀態碼: %d", status);
    }
}

// SQLite3 跨沙盒物理爆破名單中所選應用的所有鑰匙鏈（Keychain）
void deleteSelectedAppKeychain(NSArray *bundleIDs) {
    if (!bundleIDs || bundleIDs.count == 0) {
        printRealLog(@"[鑰匙串] 未勾選任何名單，跳過鑰匙鏈清洗。");
        return;
    }
    
    sqlite3 *db;
    // 🚀 【調試升級】深度捕獲打開數據庫的底層錯誤碼
    int rc = sqlite3_open("/var/keychains/keychain-2.db", &db);
    if (rc != SQLITE_OK) {
        printRealLog(@"[嚴重錯誤] 鑰匙串資料庫連接失敗: %s (錯誤碼: %d)。請務必檢查巨魔免沙盒權限！", sqlite3_errmsg(db), rc);
        return;
    }
    
    printRealLog(@"[鑰匙串] 成功連接核心 Keychain 資料庫，開始執行定點爆破...");
    
    for (NSString *bundleID in bundleIDs) {
        if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) {
            printRealLog(@"[安全攔截] 鑰匙鏈拒絕觸碰系統核心域: %@", bundleID);
            continue;
        }
        
        NSString *likePattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
        NSArray *tables = @[@"genp", @"inet", @"keys", @"cert"];
        
        for (NSString *table in tables) {
            NSString *query = [NSString stringWithFormat:@"DELETE FROM %@ WHERE agrp LIKE ?;", table];
            sqlite3_stmt *stmt;
            
            // 🚀 【調試升級】捕獲語句預編譯錯誤（全面防範表鎖死或讀寫被拒）
            int prepRc = sqlite3_prepare_v2(db, [query UTF8String], -1, &stmt, NULL);
            if (prepRc != SQLITE_OK) {
                printRealLog(@"[鑰匙串錯誤] 表 %@ 預編譯失敗: %s (代碼: %d)", table, sqlite3_errmsg(db), prepRc);
                continue;
            }
            
            sqlite3_bind_text(stmt, 1, [likePattern UTF8String], -1, SQLITE_TRANSIENT);
            
            // 🚀 【調試升級】精確追蹤單步執行狀態與實體受影響行數
            int stepRc = sqlite3_step(stmt);
            if (stepRc == SQLITE_DONE) {
                int changes = sqlite3_changes(db);
                printRealLog(@"[移除] 表 %@ 成功蒸發 %d 條關於 [%@] 的鑰匙鏈殘留憑證。", table, changes, bundleID);
            } else {
                printRealLog(@"[鑰匙串錯誤] 表 %@ 擦除執行失敗: %s (代碼: %d)", table, sqlite3_errmsg(db), stepRc);
            }
            sqlite3_finalize(stmt);
        }
    }
    sqlite3_close(db);
}

// 安全紅線濾網：深度遞歸清理 27 個自定義 var 目錄
void safeCleanDirectory(NSString *dirPath, NSArray *targetBundleIDs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir]) return;

    if ([dirPath isEqualToString:@"/var"] || [dirPath isEqualToString:@"/var/mobile"] || [dirPath isEqualToString:@"/var/root"] || [dirPath isEqualToString:@"/var/containers/Bundle"]) {
        return;
    }

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error) {
        printRealLog(@"[掃描失敗] 無法讀取目錄: %@, 原因: %@", dirPath, error.localizedDescription);
        return;
    }

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

        unsigned long long fileSize = [attrs fileSize];
        if (fileSize > 100 * 1024 * 1024) { 
            printRealLog(@"[保護熔斷] 攔截到超大資產文件, 已跳過: %@ (%llu MB)", fileName, fileSize / 1024 / 1024);
            continue;
        }

        BOOL isSubDir = [attrs.fileType isEqualToString:NSFileTypeDirectory];

        if (isSubDir) {
            // 1. 向下遞歸清空子目錄內部
            safeCleanDirectory(fullPath, targetBundleIDs);
            
            // 2. 🚀 【核心修復】子目錄內部清洗完畢後，嘗試把這個「空資料夾屍體」實體也一併拔除！
            NSError *dirDelError = nil;
            BOOL dirAllowed = NO;
            if (isPureCacheZone) {
                dirAllowed = YES;
            } else {
                for (NSString *bundleID in targetBundleIDs) {
                    if ([fileName containsString:bundleID]) { dirAllowed = YES; break; }
                }
            }
            
            if (dirAllowed) {
                if ([fm removeItemAtPath:fullPath error:&dirDelError]) {
                    printRealLog(@"[文件夾解構] 已徹底連根拔除空目錄: %@", fileName);
                } else {
                    printRealLog(@"[拒絕觸碰] 無法刪除目錄: %@, 原因: %@", fileName, dirDelError.localizedDescription);
                }
            }
        } else {
            // 執行檔案原子減法清理策略
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
                    printRealLog(@"[物理清除] 成功幹掉殘留文件: %@", fileName);
                } else {
                    // 🚀 【核心修復】把原本隱蔽、無權擦除的底層真相彻底暴露在公屏上！
                    printRealLog(@"[權限鎖死] 檔案 %@ 擦除失敗, 原因: %@", fileName, deleteError.localizedDescription);
                }
            }
        }
    }
}

// 終極再生：安全重啟用戶空間
void triggerUserspaceReboot() {
    printRealLog(@"[內核] 重置大合攏完成。正在強制安全重啟用戶空間...");
    pid_t pid;
    const char *args[] = {"/bin/launchctl", "reboot", "userspace", NULL};
    
    // 🚀 【終極解決】追蹤監控 launchctl 的生命軌跡
    int status = posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    if (status == 0) {
        printRealLog(@"[內核] launchctl 進程成功派生 (PID: %d)，基礎設施基礎服務開始切斷...", pid);
        int waitStatus = 0;
        waitpid(pid, &waitStatus, 0);
        printRealLog(@"[內核] launchctl 指令執行完畢，退出碼: %d (若系統無響應，代表內核已接管重啟流程)", waitStatus);
    } else {
        printRealLog(@"[內核嚴重錯誤] launchctl 進程派生失敗，posix_spawn 代碼: %d (請檢查巨魔特權憑證是否完整)", status);
    }
}

// ── 提權輔助器核心多軌總調度入口 ──
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 🚀 【特權顯形鏡】開機立刻把真實執行身份打在公屏上，杜絕裝盲！
        printRealLog(@"==============================================");
        printRealLog(@"[核心特權檢測] 當前進程 UID: %d , 實際有效 EUID: %d", getuid(), geteuid());
        printRealLog(@"==============================================");
        
        if (geteuid() != 0) {
            printRealLog(@"[⚠️ 嚴重警告] 當前未取得 Root(0) 身份！Keychain 爆破與核心域物理刪除將會被系統直接攔截！");
        }

        if (argc < 2) {
            printRealLog(@"[錯誤] 提權總線通信參數缺失。");
            return 1;
        }

        NSString *runMode = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray *selectedAppBundleIDs = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [selectedAppBundleIDs addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        // ==================== 軌道一：【無線輪詢自毀快刷軌】 ====================
        if ([runMode isEqualToString:@"bg_idfa_loop"]) {
            printRealLog(@"[守護] 成功激活後台無線輪詢快刷軌（免重啟模式）。");
            pid_t parentPid = getppid();
            int round = 1;
            
            while (1) {
                // 如果父進程變為 1 (被 launchd 接管) 或主 App 被用戶上劃清除，1 秒內瞬間自毀
                if (getppid() == 1 || kill(parentPid, 0) != 0) {
                    printRealLog(@"[自毀] 檢測到主App卡片已被劃退，後台守護優雅退出，0殘留。");
                    break;
                }
                
                printRealLog(@"[後台爆發] 第 %d 輪：正在強制隨機化固化 IDFA 指紋庫...", round);
                resetIDFAIdentifier();
                printRealLog(@"[成功] 第 %d 輪數據固化完成。進入睡眠等待。", round);
                
                round++;
                
                // 將 60 秒睡眠精細切碎為 60 次 1 秒試探，確保前端發射 SIGKILL 時能瞬間做出物理自毀響應
                for (int i = 0; i < 60; i++) {
                    sleep(1);
                    if (getppid() == 1 || kill(parentPid, 0) != 0) {
                        printRealLog(@"[自毀] 睡眠中途捕獲主App卡片劃退訊號，立即退出。");
                        exit(0);
                    }
                }
            }
            return 0;
        }
        
        // ==================== 軌道二：【重度深清空間軌】 ====================
        if ([runMode isEqualToString:@"standard_clean"]) {
            printRealLog(@"[提權] 成功激活重度深清軌（連動重啟用戶空間）。");
            printRealLog(@"[當前勾選清洗目標數]: %lu 個", (unsigned long)selectedAppBundleIDs.count);
            
            // 1. 強制隨機生成新廣告底座並回顯
            resetIDFAIdentifier();
            
            // 2. 清除 NVRAM 標記
            clearNVRAMVariables();
            
            // 3. SQLite3 物理爆破所選應用在系統庫中的 Keychain 痕跡
            deleteSelectedAppKeychain(selectedAppBundleIDs);
            
            // 4. 橫掃 27 個 var 自定義硬核路徑（檔案 + 空資料夾）
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
            
            printRealLog(@"[清洗] 正在橫掃 27 個 var 規則庫戰場...");
            for (NSString *path in customVarPaths) {
                safeCleanDirectory(path, selectedAppBundleIDs);
            }
            printRealLog(@"[成功] var 自定義規則庫文件與目錄減法定點清除完畢。");
            
            // 5. 甩出終極殺招，重啟用戶空間
            triggerUserspaceReboot();
        }
    }
    return 0;
}
