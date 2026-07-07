#import "DeviceInfo.h"
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

extern int sandbox_check(pid_t pid, int *operation, int flags);

@implementation DeviceInfo

+ (instancetype)sharedInstance {
    static DeviceInfo *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) { [self fetchCurrentInfo]; }
    return self;
}

- (void)fetchCurrentInfo {
    self.systemVersion = [[UIDevice currentDevice] systemVersion];
    
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *platform = [NSString stringWithUTF8String:machine];
    free(machine);
    
    [self mapDeviceAndProcessor:platform];
    
    if (sandbox_check(getpid(), NULL, 0) == 0) {
        self.isTrollStore = YES;
    } else {
        self.isTrollStore = NO;
    }
    
    self.isJailbroken = [self checkJailbreakLegacy];
    self.serialNumber = [self getInternalSerialNumber];
}

- (void)mapDeviceAndProcessor:(NSString *)platform {
    self.deviceModel = platform;
    self.processor = @"Apple Silicon";
    
    NSDictionary *modelMap = @{
        @"iPhone13,1" : @[@"iPhone 12 mini", @"Apple A14 Bionic"],
        @"iPhone13,2" : @[@"iPhone 12", @"Apple A14 Bionic"],
        @"iPhone13,3" : @[@"iPhone 12 Pro", @"Apple A14 Bionic"],
        @"iPhone13,4" : @[@"iPhone 12 Pro Max", @"Apple A14 Bionic"],
        @"iPhone14,4" : @[@"iPhone 13 mini", @"Apple A15 Bionic"],
        @"iPhone14,5" : @[@"iPhone 13", @"Apple A15 Bionic"],
        @"iPhone14,2" : @[@"iPhone 13 Pro", @"Apple A15 Bionic"],
        @"iPhone14,3" : @[@"iPhone 13 Pro Max", @"Apple A15 Bionic"],
        @"iPhone15,2" : @[@"iPhone 14 Pro", @"Apple A16 Bionic"],
        @"iPhone15,3" : @[@"iPhone 14 Pro Max", @"Apple A16 Bionic"],
        @"iPhone16,1" : @[@"iPhone 15 Pro", @"Apple A17 Pro"],
        @"iPhone16,2" : @[@"iPhone 15 Pro Max", @"Apple A17 Pro"]
    };
    NSArray *info = modelMap[platform];
    if (info) {
        self.deviceModel = info[0];
        self.processor = info[1];
    }
}

- (NSString *)getInternalSerialNumber {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!gestalt) return @"受沙盒限制";
    
    CFTypeRef (*MGCopyAnswer)(CFStringRef property) = dlsym(gestalt, "MGCopyAnswer");
    if (!MGCopyAnswer) { dlclose(gestalt); return @"受沙盒限制"; }
    
    CFStringRef key = CFSTR("SerialNumber");
    CFTypeRef answer = MGCopyAnswer(key);
    if (answer && CFGetTypeID(answer) == CFStringGetTypeID()) {
        NSString *sn = [NSString stringWithString:(__bridge NSString *)answer];
        CFRelease(answer); dlclose(gestalt); return sn;
    }
    if (answer) CFRelease(answer);
    dlclose(gestalt);
    return @"受沙盒限制";
}

- (BOOL)checkJailbreakLegacy {
    NSArray *paths = @[@"/var/jb", @"/Library/MobileSubstrate/MobileSubstrate.dylib", @"/Applications/Sileo.app"];
    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    }
    return NO;
}
@end
