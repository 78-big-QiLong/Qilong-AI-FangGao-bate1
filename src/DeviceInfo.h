#import <Foundation/Foundation.h>

@interface DeviceInfo : NSObject

@property (nonatomic, strong) NSString *systemVersion; 
@property (nonatomic, strong) NSString *deviceModel;    
@property (nonatomic, strong) NSString *serialNumber;   
@property (nonatomic, strong) NSString *processor;      
@property (nonatomic, assign) BOOL isTrollStore;        
@property (nonatomic, assign) BOOL isJailbroken;        

+ (instancetype)sharedInstance;
- (void)fetchCurrentInfo;

@end