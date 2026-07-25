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

// 0浼锛氭爣鍑嗙粓绔湡瀹炴棩蹇楄緭鍑猴紝鐩存帴瀵规帴鍓嶇 WebView 鏃ュ織闈㈡澘
void printRealLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("[ROOT_HELPER] %s\n", [message UTF8String]);
    fflush(stdout);
}

// 鈹€鈹€ 杈呭姪宸ュ叿锛歱osix_spawn 灏佽 鈹€鈹€
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

// 鈹€鈹€ 鏍稿績澶氭柟妗堣仈鍚堝畧鎶よ繘绋嬮噸杞戒笌鏉€鎴紩鎿庯紙5澶ц仈鍚堟柟妗堬紝闃查噸鍏ヤ笌澶氳繘绋嬫閿佷紭鍖栵級 鈹€鈹€
void killDaemonByName(const char *name) {
    if (!name || strlen(name) == 0) return;
    
    // 鐢ㄩ潤鎬佺嚎绋嬪畨鍏ㄩ泦鍚堣褰曟湰娆¤繍琛屼腑宸茶澶勭悊杩囩殑瀹堟姢杩涚▼锛岄槻姝㈠湪鍚屼竴绉掑唴澶氭寮烘潃瀵艰嚧 launchd 瑙﹀彂宕╂簝鍐峰嵈鏃堕棿閿佹绯荤粺
    static NSMutableSet *killedDaemons = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        killedDaemons = [[NSMutableSet alloc] init];
    });
    
    @synchronized(killedDaemons) {
        NSString *nsName = [NSString stringWithUTF8String:name];
        if ([killedDaemons containsObject:nsName]) {
            // 鏈鐢熷懡鍛ㄦ湡涓凡缁忓鐞嗚繃锛岃烦杩囬伩鍏嶉€犳垚瀹堟姢杩涚▼鎸佺画宕╂簝閲嶅惎閿佹绯荤粺
            return;
        }
        [killedDaemons addObject:nsName];
    }

    BOOL killedAny = NO;

    // 鈹€鈹€ 鏂规涓€锛氬簳灞?BSD 鍐呮牳 sysctl 杩涚▼琛ㄧ洿鎺ラ亶鍘?+ C 淇″彿鎴潃 (SIGTERM / SIGKILL) 鈹€鈹€
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
        struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
        if (procs && sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
            int count = (int)(size / sizeof(struct kinfo_proc));
            for (int i = 0; i < count; i++) {
                char *comm = procs[i].kp_proc.p_comm;
                if (comm && strstr(comm, name) != NULL) {
                    pid_t targetPid = procs[i].kp_proc.p_pid;
                    if (targetPid > 1 && targetPid != getpid()) {
                        kill(targetPid, SIGTERM);
                        kill(targetPid, SIGKILL);
                        killedAny = YES;
                    }
                }
            }
        }
        if (procs) free(procs);
    }

    // 鈹€鈹€ 鍔ㄦ€侀樁姊洖閫€锛氳嫢鏂规涓€宸叉垚鍔熼€氳繃鍐呮牳鏉€姝昏繘绋嬶紝鍒欎笉鍐嶆墽琛岃€楁椂鐨勫懡浠よ杩涚▼鐢熸垚锛屾潨缁濇暟鍗佺鍗℃ 鈹€鈹€
    if (!killedAny) {
        // 鈹€鈹€ 鏂规浜岋細鎵ц iOS 鏍囧噯璺緞涓嬬殑 killall -9 鈹€鈹€
        {
            const char *args[] = {"/usr/bin/killall", "-9", name, NULL};
            int ret = spawnAndWait(args[0], args);
            if (ret == 0) killedAny = YES;
        }

        // 鈹€鈹€ 鏂规涓夛細鍏煎 Rootless 瓒婄嫳璺緞涓嬬殑 killall -9 鈹€鈹€
        if (!killedAny) {
            const char *args[] = {"/var/jb/usr/bin/killall", "-9", name, NULL};
            int ret = spawnAndWait(args[0], args);
            if (ret == 0) killedAny = YES;
        }

        // 鈹€鈹€ 鏂规鍥涳細閫氳繃 launchctl 鍋滄/閲嶇疆鐩稿叧绯荤粺鏈嶅姟 鈹€鈹€
        if (!killedAny) {
            NSString *serviceName = [NSString stringWithFormat:@"com.apple.%s", name];
            const char *args[] = {"/bin/launchctl", "stop", [serviceName UTF8String], NULL};
            spawnAndWait(args[0], args);
        }
    }

    // 鈹€鈹€ 鏂规浜旓細鍙戝皠 Darwin IPC 骞挎挱鍌績瀹堟姢杩涚▼閲嶈浇鍋忓ソ缂撳瓨 鈹€鈹€
    {
        char notifyBuf[256];
        snprintf(notifyBuf, sizeof(notifyBuf), "com.apple.%s.changed", name);
        notify_post(notifyBuf);
        notify_post("com.apple.cfprefsd.defaults-changed");
    }

    if (killedAny) {
        printRealLog(@"[PROCESS] Multi-scheme reset triggered for daemon: %s", name);
    }
}

// ============================================================================
// IDFA + IDFV 鍏ㄧ淮搴﹀己鍒跺埛鏂帮紙涓夐亶瑕嗗啓 + 璇诲彇鍥炴樉 + 澶氬眰鏂囦欢娣卞害鏀瑰啓锛?
// ============================================================================
void resetIDFAIdentifier() {
    NSString *adPlist = @"/var/mobile/Library/Preferences/com.apple.AdLib.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (int i = 1; i <= 3; i++) {
        NSString *newUUID = [[NSUUID UUID] UUIDString];
        NSString *newVendorUUID = [[NSUUID UUID] UUIDString];
        
        // 鈹€鈹€ 鏂规A锛氱洿鎺ヨ鍐?AdLib plist 鈹€鈹€
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:adPlist];
        if (!dict) dict = [NSMutableDictionary dictionary];
        [dict setObject:newUUID forKey:@"ADI_DEVICE_IDENTIFIER_DEPRECATED"];
        [dict setObject:newUUID forKey:@"AdvertisingIdentifier"];
        [dict setObject:newUUID forKey:@"IDFA"];
        [dict setObject:@(YES) forKey:@"LimitAdTracking"];
        [dict setObject:@(YES) forKey:@"forceLimitAdTracking"];
        [dict writeToFile:adPlist atomically:YES];
        
        // 鈹€鈹€ 鏂规B锛氶€氳繃 MobileGestalt 鐩存帴娉ㄥ叆锛堜笉闇€瑕侀噸鍚級 鈹€鈹€
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
        
        // 鈹€鈹€ 鏂规C锛氳鍐?identifierForAdvertising 搴曞眰缂撳瓨 plist 鈹€鈹€
        NSString *adIdPlist2 = @"/var/mobile/Library/Preferences/com.apple.AdServices.plist";
        NSMutableDictionary *adDict2 = [NSMutableDictionary dictionaryWithContentsOfFile:adIdPlist2];
        if (!adDict2) adDict2 = [NSMutableDictionary dictionary];
        [adDict2 setObject:newUUID forKey:@"adsIdentifier"];
        [adDict2 writeToFile:adIdPlist2 atomically:YES];
        
        // 鈹€鈹€ 鏂规D锛氳鍐?identifierForVendor 搴曞眰缂撳瓨 鈹€鈹€
        NSString *vendorPlist = @"/var/mobile/Library/Preferences/com.apple.identifierForVendor.plist";
        NSMutableDictionary *vendorDict = [NSMutableDictionary dictionaryWithContentsOfFile:vendorPlist];
        if (!vendorDict) vendorDict = [NSMutableDictionary dictionary];
        [vendorDict setObject:newVendorUUID forKey:@"VendorIdentifier"];
        [vendorDict setObject:newVendorUUID forKey:@"IdentifierForVendor"];
        [vendorDict writeToFile:vendorPlist atomically:YES];
        
        // 鈹€鈹€ 鏂规E锛氭竻闄ゆ墍鏈?IDFV 鐩稿叧鐨?Keychain 鏉＄洰 鈹€鈹€
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

        // 鈹€鈹€ 鏂规F锛堟柊澧烇級锛氱洿鎺ヨ鍐?LaunchServices IDFV 鏄犲皠缂撳瓨搴?plist 鈹€鈹€
        NSString *lsdPlist = @"/var/mobile/Library/Preferences/com.apple.lsd.identifiers.plist";
        NSMutableDictionary *lsdDict = [NSMutableDictionary dictionaryWithContentsOfFile:lsdPlist];
        if (!lsdDict) lsdDict = [NSMutableDictionary dictionary];
        [lsdDict setObject:newVendorUUID forKey:@"VendorIdentifier"];
        [lsdDict writeToFile:lsdPlist atomically:YES];

        // 鈹€鈹€ 鏂规G锛堟柊澧烇級锛氳鍐?AdPlatforms 涓?AdPrivacy 绛夊叏閮ㄥ箍鍛婂叧鑱?plist 鈹€鈹€
        NSArray *adPlists = @[
            @"/var/mobile/Library/Preferences/com.apple.AdPlatforms.plist",
            @"/var/mobile/Library/Preferences/com.apple.adprivacyd.plist",
            @"/var/mobile/Library/Preferences/com.apple.adservicesd.plist"
        ];
        for (NSString *pPath in adPlists) {
            NSMutableDictionary *pDict = [NSMutableDictionary dictionaryWithContentsOfFile:pPath];
            if (!pDict) pDict = [NSMutableDictionary dictionary];
            [pDict setObject:newUUID forKey:@"deviceIdentifier"];
            [pDict setObject:newUUID forKey:@"advertisingId"];
            [pDict writeToFile:pPath atomically:YES];
        }

        // 鈹€鈹€ 鏂规H锛堟柊澧烇級锛氳鍐?GlobalPreferences 鍏ㄥ眬鍙傛暟琛ㄤ腑鐨勮拷韪?UUID 瀛楁 鈹€鈹€
        NSArray *globalPlists = @[
            @"/var/mobile/Library/Preferences/.GlobalPreferences.plist",
            @"/var/root/Library/Preferences/.GlobalPreferences.plist",
            @"/var/mobile/Library/Preferences/com.apple.device-identification.plist"
        ];
        for (NSString *gPath in globalPlists) {
            if ([fm fileExistsAtPath:gPath]) {
                NSMutableDictionary *gDict = [NSMutableDictionary dictionaryWithContentsOfFile:gPath];
                if (gDict) {
                    if (gDict[@"AdvertisingIdentifier"]) gDict[@"AdvertisingIdentifier"] = newUUID;
                    if (gDict[@"VendorIdentifier"]) gDict[@"VendorIdentifier"] = newVendorUUID;
                    [gDict writeToFile:gPath atomically:YES];
                }
            }
        }

        // 鈹€鈹€ 鏂规I锛堟柊澧烇級锛氬己鍒剁墿鐞嗘姽闄?LSD / AdLib 搴曞眰纾佺洏缂撳瓨鐩綍 鈹€鈹€
        NSArray *cacheDirs = @[
            @"/var/mobile/Library/Caches/com.apple.lsd",
            @"/var/mobile/Library/Caches/com.apple.AdLib",
            @"/var/mobile/Library/Caches/com.apple.AdServices"
        ];
        for (NSString *cDir in cacheDirs) {
            if ([fm fileExistsAtPath:cDir]) {
                [fm removeItemAtPath:cDir error:nil];
            }
        }

        // 鈹€鈹€ 骞挎挱鍌績绯荤粺瀹堟姢杩涚▼鍚屾 鈹€鈹€
        notify_post("com.apple.AdLib.LimitAdTrackingChanged");
        notify_post("com.apple.idfa.changed");
        notify_post("com.apple.identityservicesd.idchanged");
        notify_post("com.apple.MobileGestalt.didChange");
        
        // 鍙嶅悜閲嶈楠岃瘉
        NSDictionary *verifyDict = [NSDictionary dictionaryWithContentsOfFile:adPlist];
        NSString *currentIDFA = verifyDict[@"AdvertisingIdentifier"] ?: @"READ_FAILED";
        NSDictionary *verifyVendor = [NSDictionary dictionaryWithContentsOfFile:vendorPlist];
        NSString *currentIDFV = verifyVendor[@"VendorIdentifier"] ?: newVendorUUID;
        
        printRealLog(@"[IDFA] Round %d: New IDFA = %@", i, currentIDFA);
        printRealLog(@"[IDFV] Round %d: New IDFV = %@", i, currentIDFV);
    }
    
    // 鈹€鈹€ 鏂规J锛堟柊澧炲寮猴級锛氭潃姝?cfprefsd / lsd 绛夊亸濂界紦瀛樺畧鎶よ繘绋嬪己杩粠纾佺洏閲嶈鏂囦欢 鈹€鈹€
    killDaemonByName("adprivacyd");
    killDaemonByName("adid");
    killDaemonByName("AdServices");
    killDaemonByName("cfprefsd");
    killDaemonByName("lsd");
    printRealLog(@"[IDFA] Multi-scheme IDFA+IDFV file override & daemon reset complete.");
}

// ============================================================================
// Keychain 澶氭柟妗堣仈鍚堟竻鐞?(8 澶ц仈鍚堟繁搴︽柟妗?
// ============================================================================
void deleteSelectedAppKeychain(NSArray *bundleIDs) {
    if (!bundleIDs || bundleIDs.count == 0) {
        printRealLog(@"[KEYCHAIN] No target selected. Skipping.");
        return;
    }
    
    // 鈹€鈹€ 鏂规1锛歋QLite 鐩存帴鍒犻櫎 keychain-2.db 鈹€鈹€
    printRealLog(@"[KEYCHAIN] Method 1: SQLite agrp direct delete...");
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
    
    // 鈹€鈹€ 鏂规2锛氭墿灞曞尮閰?- 鍒犻櫎鍖呭惈 bundleID 鍦?svce/acct/sdmn 鍒椾腑鐨勬潯鐩?鈹€鈹€
    printRealLog(@"[KEYCHAIN] Method 2: Extended column match...");
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
        for (NSString *bundleID in bundleIDs) {
            if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) continue;
            
            NSString *likePattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
            NSArray *tables = @[@"genp", @"inet"];
            
            for (NSString *table in tables) {
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

    // 鈹€鈹€ 鏂规6锛堟柊澧烇級锛氭繁搴︽壂鎻?TEXT/BLOB 鍒?(data/labl/desc/cmnt) 鈹€鈹€
    printRealLog(@"[KEYCHAIN] Method 6: Deep payload & label matching...");
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
        for (NSString *bundleID in bundleIDs) {
            if (bundleID.length < 5 || [bundleID hasPrefix:@"com.apple."]) continue;
            NSString *likePattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
            NSArray *tables = @[@"genp", @"inet", @"cert", @"keys"];
            for (NSString *table in tables) {
                NSArray *cols = @[@"data", @"labl", @"desc", @"cmnt"];
                for (NSString *col in cols) {
                    NSString *query = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ LIKE ?;", table, col];
                    sqlite3_stmt *stmt;
                    if (sqlite3_prepare_v2(db, [query UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
                        sqlite3_bind_text(stmt, 1, [likePattern UTF8String], -1, SQLITE_TRANSIENT);
                        if (sqlite3_step(stmt) == SQLITE_DONE) {
                            int changes = sqlite3_changes(db);
                            if (changes > 0) {
                                printRealLog(@"[KEYCHAIN] Deep Match %@.%@: Deleted %d records.", table, col, changes);
                            }
                        }
                        sqlite3_finalize(stmt);
                    }
                }
            }
        }
        sqlite3_close(db);
    }
    
    // 鈹€鈹€ 鏂规3锛歐AL checkpoint 寮哄埗鍐欏叆 + VACUUM 鍘嬬缉 鈹€鈹€
    printRealLog(@"[KEYCHAIN] Method 3: WAL checkpoint + VACUUM...");
    if (sqlite3_open("/var/keychains/keychain-2.db", &db) == SQLITE_OK) {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
        sqlite3_exec(db, "VACUUM;", NULL, NULL, NULL);
        sqlite3_close(db);
        printRealLog(@"[KEYCHAIN] DB compacted successfully.");
    }
    
    // 鈹€鈹€ 鏂规4锛氬垹闄?keychain WAL/SHM 娈嬬暀鏂囦欢 鈹€鈹€
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

    // 鈹€鈹€ 鏂规7锛堟柊澧烇級锛氭竻鐞?Keychain 鐩綍涓存椂涓庡奖瀛愮紦瀛樹欢 鈹€鈹€
    printRealLog(@"[KEYCHAIN] Method 7: Purging shadow keychain caches...");
    NSArray *keychainDirs = @[@"/var/Keychains", @"/var/mobile/Library/Keychains"];
    for (NSString *kDir in keychainDirs) {
        NSArray *kFiles = [fm contentsOfDirectoryAtPath:kDir error:nil];
        for (NSString *kFile in kFiles) {
            if ([kFile hasSuffix:@"-shm"] || [kFile hasSuffix:@"-wal"] || [kFile hasPrefix:@"sb-"]) {
                NSString *fullKPath = [kDir stringByAppendingPathComponent:kFile];
                [fm removeItemAtPath:fullKPath error:nil];
            }
        }
    }

    // 鈹€鈹€ 鏂规8锛堟柊澧烇級锛氱墿鐞嗘姽闄?security/securityd 纾佺洏杩愯鎬佺紦瀛?鈹€鈹€
    printRealLog(@"[KEYCHAIN] Method 8: Cleaning securityd disk caches...");
    NSArray *secCaches = @[
        @"/var/mobile/Library/Caches/com.apple.security.keychain",
        @"/var/mobile/Library/Caches/com.apple.securityd"
    ];
    for (NSString *secDir in secCaches) {
        if ([fm fileExistsAtPath:secDir]) {
            [fm removeItemAtPath:secDir error:nil];
        }
    }
    
    // 鈹€鈹€ 鏂规5锛氭潃姝?securityd 寮哄埗绔嬪嵆閲嶈浇锛堟棤闇€閲嶅惎锛?鈹€鈹€
    killDaemonByName("securityd");
    printRealLog(@"[KEYCHAIN] securityd killed. Keychain cache invalidated.");
}

// ============================================================================
// NVRAM 涓庣‖浠惰拷婧鏂规鑱斿悎娓呯悊 (6 澶ц仈鍚堟繁搴︽柟妗?
// ============================================================================
void clearNVRAMVariables() {
    printRealLog(@"[NVRAM] Starting multi-method erase...");
    
    // 鈹€鈹€ 鏂规1锛歯vram -c 娓呯┖鎵€鏈夐潪纭欢閿佹鍙橀噺锛堟敮鎸佹爣鍑嗗拰瓒婄嫳璺緞澶氶噸閲嶈瘯锛?鈹€鈹€
    printRealLog(@"[NVRAM] Method 1: nvram -c...");
    {
        const char *args1[] = {"/usr/sbin/nvram", "-c", NULL};
        int ret = spawnAndWait(args1[0], args1);
        if (ret != 0) {
            const char *args2[] = {"/var/jb/usr/sbin/nvram", "-c", NULL};
            ret = spawnAndWait(args2[0], args2);
        }
        printRealLog(@"[NVRAM] Method 1: status = %d.", ret);
    }
    
    // 鈹€鈹€ 鏂规2锛氶€愪竴鍒犻櫎宸茬煡鐨勮拷韪浉鍏?NVRAM 鍙橀噺锛堟敮鎸佸鏉¤矾寰勫皾璇曪級 鈹€鈹€
    printRealLog(@"[NVRAM] Method 2: Targeted variable delete...");
    NSArray *nvramKeys = @[
        @"auto-boot", @"boot-args", @"SystemAudioVolumeSaved",
        @"bluetoothExternalDongleFailed", @"bluetoothInternalControllerInfo",
        @"fmm-computer-name", @"prev-lang:kbd", @"LocationServicesEnabled",
        @"com.apple.System.boot-nonce", @"USBPortAssignment"
    ];
    for (NSString *key in nvramKeys) {
        const char *args1[] = {"/usr/sbin/nvram", "-d", [key UTF8String], NULL};
        if (spawnAndWait(args1[0], args1) != 0) {
            const char *args2[] = {"/var/jb/usr/sbin/nvram", "-d", [key UTF8String], NULL};
            spawnAndWait(args2[0], args2);
        }
    }
    printRealLog(@"[NVRAM] Method 2: Targeted keys purged.");
    
    // 鈹€鈹€ 鏂规3锛氶€氳繃 dlsym 鍔ㄦ€佸姞杞?IOKit 鎿嶄綔 NVRAM锛堢粫杩?iOS SDK 闄愬埗锛?鈹€鈹€
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
    
    // 鈹€鈹€ 鏂规4锛氬垹闄?NVRAM 鎸佷箙鍖栫紦瀛樻枃浠讹紙瀹夊叏绾㈢嚎锛氫笉鐮村潖绯荤粺婵€娲诲熀纭€锛?鈹€鈹€
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *nvramCacheFiles = @[
        @"/var/mobile/Library/Preferences/com.apple.device-identification.plist"
    ];
    for (NSString *path in nvramCacheFiles) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
            printRealLog(@"[NVRAM] Removed cache file: %@", [path lastPathComponent]);
        }
    }

    // 鈹€鈹€ 鏂规5锛堟柊澧烇級锛氶噸缃?SystemConfiguration 纭欢涓庣綉缁滃敮涓€绛惧悕缂撳瓨 鈹€鈹€
    printRealLog(@"[NVRAM] Method 5: Resetting SystemConfiguration signature files...");
    NSArray *sysConfigPlists = @[
        @"/var/preferences/SystemConfiguration/preferences.plist",
        @"/var/preferences/SystemConfiguration/com.apple.networkidentification.plist"
    ];
    for (NSString *scPath in sysConfigPlists) {
        if ([fm fileExistsAtPath:scPath]) {
            NSMutableDictionary *scDict = [NSMutableDictionary dictionaryWithContentsOfFile:scPath];
            if (scDict) {
                [scDict removeObjectForKey:@"NetworkIdentification"];
                [scDict writeToFile:scPath atomically:YES];
                printRealLog(@"[NVRAM] Cleared network signature in %@", [scPath lastPathComponent]);
            }
        }
    }

    // 鈹€鈹€ 鏂规6锛堟柊澧烇級锛氭竻鐞?uuidtext 涓庤瘖鏂褰曡冻杩?鈹€鈹€
    printRealLog(@"[NVRAM] Method 6: Purging uuidtext / diagnostic ID footprints...");
    NSArray *diagDirs = @[@"/var/db/uuidtext", @"/var/db/diagnostics"];
    for (NSString *diagDir in diagDirs) {
        if ([fm fileExistsAtPath:diagDir]) {
            [fm removeItemAtPath:diagDir error:nil];
            printRealLog(@"[NVRAM] Purged diagnostic trace: %@", diagDir);
        }
    }
    
    printRealLog(@"[NVRAM] Multi-method erase complete.");
}

// ============================================================================
// Clean shared and plugin containers matching bundle IDs
// ============================================================================
int cleanSpecialContainers(NSString *containersRoot, NSArray *targetBundleIDs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:containersRoot error:&error];
    if (error) return 0;
    
    int cleanedCount = 0;
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
                                cleanedCount++;
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
    return cleanedCount;
}

// Clean Safari cookies/history and WebKit web cache
int cleanSafariAndWebKit() {
    NSFileManager *fm = [NSFileManager defaultManager];
    int cleanedCount = 0;
    
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
                cleanedCount++;
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
            cleanedCount++;
        } else {
            printRealLog(@"[ERROR] Failed to remove WebKit cache. Reason: %@", err.localizedDescription);
        }
    }
    return cleanedCount;
}

// 瀹夊叏绾㈢嚎婊ょ綉锛氭繁搴﹂€掑綊娓呯悊鑷畾涔?var 鐩綍
int safeCleanDirectory(NSString *dirPath, NSArray *targetBundleIDs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir]) return 0;

    // 椤剁骇閬胯锛氱粷瀵圭姝㈢墿鐞嗘姽闄ょ敤鎴峰眰涓庣郴缁熷簳灞傚熀鐭崇洰褰曟湰韬?
    if ([dirPath isEqualToString:@"/var"] || [dirPath isEqualToString:@"/var/mobile"] || [dirPath isEqualToString:@"/var/root"] || [dirPath isEqualToString:@"/var/containers/Bundle"]) {
        return 0;
    }

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error) return 0;

    int cleanedCount = 0;

    // 鍒ゆ柇褰撳墠鐩綍鏄惁灞炰簬"鍏叡绾紦瀛樹涪寮冨尯"
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

        // 閾佸緥绾㈢嚎涓€锛氬ぇ鏂囦欢寮鸿鐔旀柇閿?(>100MB 璧勪骇鐩存帴鏀捐)
        unsigned long long fileSize = [attrs fileSize];
        if (fileSize > 100 * 1024 * 1024) { 
            printRealLog(@"[LIMIT] Skipped large file (>100MB): %@ (%llu MB)", fileName, fileSize / 1024 / 1024);
            continue;
        }

        BOOL isSubDir = [attrs.fileType isEqualToString:NSFileTypeDirectory];

        if (isSubDir) {
            cleanedCount += safeCleanDirectory(fullPath, targetBundleIDs);
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
                    cleanedCount++;
                } else if (deleteError) {
                    printRealLog(@"[ERROR] Permission denied: %@. Reason: %@", fileName, deleteError.localizedDescription);
                }
            }
        }
    }
    
    // 杩炴牴鎷旈櫎锛氶€掑綊娓呯悊瀹屾瘯鍚庯紝鑻ュ綋鍓嶇洰褰曞凡鎴愮┖澹冲垯鐗╃悊鎷旈櫎
    NSArray *remaining = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (remaining && remaining.count == 0) {
        NSError *rmDirErr = nil;
        if ([fm removeItemAtPath:dirPath error:&rmDirErr]) {
            printRealLog(@"[CLEAN] Removed empty dir: %@", dirPath);
            cleanedCount++;
        }
    }
    return cleanedCount;
}

// ============================================================================
// 鏃犻渶閲嶅惎鐨勫畧鎶よ繘绋嬮噸杞芥柟妗?
// ============================================================================
void forceRefreshWithoutReboot() {
    printRealLog(@"[REFRESH] Killing daemons to force immediate effect (no reboot)...");
    
    // 鏉€姝诲箍鍛婄浉鍏冲畧鎶よ繘绋?
    killDaemonByName("adprivacyd");
    killDaemonByName("adid");
    
    // 鏉€姝?keychain 瀹堟姢杩涚▼
    killDaemonByName("securityd");
    
    // 鏉€姝?cfprefsd 鍒锋柊 plist 缂撳瓨
    killDaemonByName("cfprefsd");
    
    // 鏉€姝?nfcd锛圢FC 鎸囩汗鐩稿叧锛?
    killDaemonByName("nfcd");
    
    // 鏉€姝诲悗鍙板垎鏋愬畧鎶よ繘绋?
    killDaemonByName("analyticsd");
    killDaemonByName("diagnosticd");
    
    // 鍙戝皠鍏ㄧ淮搴︾郴缁熷箍鎾偓淇冨埛鏂?
    notify_post("com.apple.AdLib.LimitAdTrackingChanged");
    notify_post("com.apple.idfa.changed");
    notify_post("com.apple.identityservicesd.idchanged");
    notify_post("com.apple.MobileGestalt.didChange");
    notify_post("com.apple.pasteboard.changed");
    notify_post("com.apple.system.config.network_change");
    notify_post("com.apple.springboard.finishedstartup");
    
    printRealLog(@"[REFRESH] All daemons killed + broadcasts sent. Effect immediate.");
}

// 缁堟瀬鍐嶇敓锛氬畨鍏ㄩ噸鍚敤鎴风┖闂达紙寮傛閲婃斁鏂规锛岃В闄?launchd 杩涚▼閾炬閿侊級
void triggerUserspaceReboot() {
    printRealLog(@"[KERNEL] Cleaning complete. Triggering userspace reboot...");
    
    // 鏂规涓€锛氭爣鍑嗚矾寰?launchctl reboot userspace
    {
        pid_t pid;
        const char *args[] = {"/bin/launchctl", "reboot", "userspace", NULL};
        posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    }
    
    // 鏂规浜岋細Rootless 璺緞 launchctl reboot userspace
    {
        pid_t pid;
        const char *args[] = {"/var/jb/bin/launchctl", "reboot", "userspace", NULL};
        posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    }
    
    // 鈿狅笍 鏋佸叾鍏抽敭锛氬繀椤诲湪姝ゅ绔嬪嵆 exit(0) 閫€鍑哄綋鍓?RootHelper 浜岃繘鍒讹紒
    // 鍚﹀垯 RootHelper 浼氫竴鐩寸暀鍦ㄥ唴瀛樹腑绛夊緟瀛愯繘绋嬬粨鏉燂紝鑰?launchd 鍦ㄦ墽琛?userspace 閲嶅惎鏃跺張鍦ㄧ瓑寰?RootHelper 閫€鍑猴紝
    // 浠庤€屽鑷撮暱杈惧崄鍑犵鐨勫弻鍚戞閿佸崱姝汇€傜珛鍗抽€€鍑哄悗锛岀敤鎴风┖闂撮噸鍚細鐬棿鏃犵紳鎵ц銆?
    exit(0);
}

// 鈹€鈹€ 鎻愭潈杈呭姪鍣ㄦ牳蹇冨杞ㄦ€昏皟搴﹀叆鍙?鈹€鈹€
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 鍙傛暟瓒婄晫闃查敊
        if (argc < 2) {
            printRealLog(@"[ERROR] Missing required arguments.");
            return 1;
        }

        // 瑙ｆ瀽浠?main.m 璺敱杩囨潵鐨勮繍琛岃建妯″紡鏆楀彿
        NSString *runMode = [NSString stringWithUTF8String:argv[1]];
        
        // 鍔ㄦ€佸挰鍚堬細鎻愬彇骞剁粍瑁呯敤鎴风湡姝ｅ嬀閫夌殑鍏ㄩ儴鐩爣搴旂敤 Bundle ID 鍚嶅崟
        NSMutableArray *selectedAppBundleIDs = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [selectedAppBundleIDs addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        // ==================== 杞ㄩ亾涓€锛氥€愭棤绾胯疆璇㈣嚜姣佸揩鍒疯建銆?====================
        if ([runMode isEqualToString:@"bg_idfa_loop"]) {
            printRealLog(@"[DAEMON] Background loop active.");
            
            pid_t parentPid = getppid();
            int round = 1;
            
            while (1) {
                // 銆怶atchdog鍗＄偣 A銆戠埗杩涚▼鍙樹负 1 鎴栬鏉€
                if (getppid() == 1 || kill(parentPid, 0) != 0) {
                    printRealLog(@"[DAEMON] Parent process killed. Exiting.");
                    break;
                }
                
                printRealLog(@"[DAEMON] Round %d: Overwriting IDFA+IDFV...", round);
                resetIDFAIdentifier();
                
                // 姣忚疆鍒锋柊鍚庣珛鍗虫潃姝诲畧鎶よ繘绋嬩娇鍏剁敓鏁?
                forceRefreshWithoutReboot();
                
                printRealLog(@"[DAEMON] Round %d complete. Waiting 60s.", round);
                
                round++;
                
                // 60绉掑垏纰庝负60娆?绉掕瘯鎺?
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

        // ==================== 杞ㄩ亾涓€杞┖鐐癸細銆愬叏鐩樺叏灞€澶氭柟妗堟棤寤惰繜瀹炴椂鎵弿娓呯悊杞ㄣ€?====================
        if ([runMode isEqualToString:@"realtime_whitelist_clean"]) {
            printRealLog(@"[REALTIME] Dynamic Whitelist Multi-Method Continuous Realtime Clean Active.");
            printRealLog(@"[REALTIME] Enforcing safe multi-scheme clean (IDFA + Safe Var Caches + AppGroup + WebKit).");

            pid_t parentPid = getppid();
            
            // 瀹夊叏缁濇潃锛氶璁剧粷瀵逛笉鍙竻鐞嗙殑纭牳绯荤粺涓庡畨鍏ㄤ繚鎶よ矾寰?ID锛岄槻姝㈣瑙?
            NSArray *strictSystemWhitelist = @[
                @"com.apple.", @"org.trollstore", @"com.opa334.", @"/var/mobile/Library/Preferences/com.apple",
                @"/var/preferences/SystemConfiguration", @"/var/db/diagnostics"
            ];

            // 馃攳 鎷撳睍瀹夊叏鐨?`/var` 绾紦瀛樹笌涓存椂娈嬬暀娓呯悊璺緞锛?00% 涓嶅奖鍝嶇郴缁熺ǔ瀹氭€э級
            NSArray *customVarPaths = @[
                @"/var/mobile/Library/Caches",
                @"/var/mobile/Library/Cookies",
                @"/var/mobile/Library/HTTPStorages",
                @"/var/mobile/Library/Saved Application State",
                @"/var/mobile/Library/SplashBoard/Snapshots",
                @"/var/mobile/Library/WebKit",
                @"/var/mobile/Library/Logs",
                @"/var/mobile/Library/Logs/CrashReporter",
                @"/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
                @"/var/mobile/Library/Caches/com.apple.WebKit.Networking",
                @"/var/root/Library/Caches",
                @"/var/root/Library/HTTPStorages",
                @"/var/root/Library/Tmp",
                @"/var/tmp",
                @"/var/mobile/Containers/Shared/AppGroup",
                @"/var/mobile/Containers/Data/PluginKitPlugin"
            ];

            int scanCyclesInWindow = 0;
            int cleanedFilesInWindow = 0;
            time_t windowStart = time(NULL);

            while (1) {
                @autoreleasepool {
                    // 鐪嬮棬鐙楁鏍★細涓荤▼搴忔寕鎺夋椂鑷姩閫€鍦?
                    if (getppid() == 1 || kill(parentPid, 0) != 0) {
                        printRealLog(@"[REALTIME] Parent app closed. Terminating realtime daemon.");
                        break;
                    }

                    scanCyclesInWindow++;

                    // 1. 瀹炴椂杞婚噺閲嶇疆 IDFA/IDFV Plist 缂撳瓨 (涓嶈Е鍙戝己鏉€锛屼繚鎸佸墠鍙伴『鐣?
                    resetIDFAIdentifier();

                    // 2. 瀹炴椂鎶归櫎鍓创鏉跨紦瀛樺苟鍙戦€佸箍鎾?
                    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Caches/com.apple.Pasteboard"]) {
                        if ([[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.apple.Pasteboard" error:nil]) {
                            cleanedFilesInWindow++;
                            notify_post("com.apple.pasteboard.changed");
                        }
                    }

                    // 3. 瀹炴椂鎵弿娓呯悊 Safari & WebKit 缂撳瓨瓒宠抗
                    cleanedFilesInWindow += cleanSafariAndWebKit();

                    // 4. 鍏ㄥ眬瀹炴椂鎵弿甯搁┗ Safe Var 缂撳瓨璺緞
                    for (NSString *targetPath in customVarPaths) {
                        cleanedFilesInWindow += safeCleanDirectory(targetPath, selectedAppBundleIDs);
                    }

                    // 5. 娓呯悊鍏变韩 AppGroup 鍙?PluginKit 鎻掍欢鐗规潈鍖?
                    cleanedFilesInWindow += cleanSpecialContainers(@"/var/mobile/Containers/Shared/AppGroup", selectedAppBundleIDs);
                    cleanedFilesInWindow += cleanSpecialContainers(@"/var/mobile/Containers/Data/PluginKitPlugin", selectedAppBundleIDs);
                    // 瀹炴椂杈撳嚭姣忎竴杞壂鎻忕姸鎬侊紝纭繚鏃ュ織闈㈡澘鏈夋寔缁洖鏄?
                    printRealLog(@"[REALTIME] Pass #%d: Scanned safe /var paths. Cleaned in pass: %d files.", scanCyclesInWindow, cleanedFilesInWindow);

                    // 6. 姣?60 绉掑ぇ鍛ㄦ湡鍒拌揪鏃讹紝缁熶竴鎵ц浣庨 Keychain 鎶归櫎涓庤交閲忓箍鎾噸杞斤紙閬垮厤楂橀寮烘潃 securityd锛?
                    time_t now = time(NULL);
                    if (now - windowStart >= 60) {
                        if (selectedAppBundleIDs.count > 0 && cleanedFilesInWindow > 0) {
                            deleteSelectedAppKeychain(selectedAppBundleIDs);
                        }
                        
                        // 鍙戝皠 Darwin IPC 骞挎挱鍌績瀹堟姢杩涚▼鍒锋柊鍋忓ソ锛堟棤寮烘潃锛屽墠鍙伴浂鍗￠】锛?
                        notify_post("com.apple.idfa.changed");
                        notify_post("com.apple.pasteboard.changed");

                        printRealLog(@"[REALTIME] Telemetry Summary (Past 60s): Scanned %d passes, Cleaned %d files total. System active & safe.", scanCyclesInWindow, cleanedFilesInWindow);
                        printRealLog(@"[REALTIME] Round complete. Waiting 60s window reset.");
                        
                        // 閲嶇疆 60 绉掔粺璁＄獥鍙?
                        scanCyclesInWindow = 0;
                        cleanedFilesInWindow = 0;
                        windowStart = now;
                    }
                }

                // 2 绉掍竴娆¤疆璇㈡壂鎻忥紝鏃㈣兘淇濊瘉楂樺搷搴旈€熷害锛屽張鑳界‘淇?stdout 瀹炴椂鍒峰埌 WebView
                sleep(2);
            }
            return 0;
        }
        
        // ==================== 杞ㄩ亾浜岋細銆愰噸搴︽繁娓呯┖闂磋建銆?====================
        if ([runMode isEqualToString:@"standard_clean"]) {
            printRealLog(@"[KERNEL] Active: Deep clean mode.");
            printRealLog(@"[KERNEL] Target count: %lu", (unsigned long)selectedAppBundleIDs.count);
            
            // 1. 寮哄埗瑕嗗啓涓夐亶闅忔満 UUID锛圛DFA + IDFV锛?
            resetIDFAIdentifier();
            printRealLog(@"[IDFA] Multi-method IDFA+IDFV refresh complete.");
            
            // 2. 澶氭柟妗堟竻闄?NVRAM
            clearNVRAMVariables();
            
            // 3. 澶氭柟妗堣仈鍚?Keychain 娓呯悊
            deleteSelectedAppKeychain(selectedAppBundleIDs);
            
            // 3.5 娓呯悊 Safari 鐨勫叏灞€ Cookie銆佺綉椤电姸鎬佸強 WebKit 璺ㄨ繘绋嬬紦瀛?
            cleanSafariAndWebKit();
            
            // 3.6 鐗╃悊鎶归櫎鍓创绨跨紦瀛樺苟鍚屾鍙戝皠骞挎挱
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.apple.Pasteboard" error:nil];
            notify_post("com.apple.pasteboard.changed");
            printRealLog(@"[CLEAN] Clipboard cache erased.");
            
            // 3.7 娓呮礂鍏变韩鐗规潈鐩綍
            cleanSpecialContainers(@"/var/mobile/Containers/Shared/AppGroup", selectedAppBundleIDs);
            cleanSpecialContainers(@"/var/mobile/Containers/Data/PluginKitPlugin", selectedAppBundleIDs);
            
            // 4. 妯壂鑷畾涔夌‖鏍搁噸鐏捐矾寰?
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
            
            // 5. 鍏堟墽琛屾棤閲嶅惎鏂规寮哄埗绔嬪嵆鐢熸晥
            forceRefreshWithoutReboot();
            
            // 6. 鏈€缁堥噸鍚敤鎴风┖闂村埛鏂板叏鏈鸿繘绋嬬紦瀛?
            triggerUserspaceReboot();
        }
    }
    return 0;
}
