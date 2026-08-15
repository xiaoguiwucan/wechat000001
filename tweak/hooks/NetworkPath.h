#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const WXIngestNetworkDidChangeNotification;

@interface WXIngestNetwork : NSObject

+ (void)start;
+ (BOOL)wifiActive;
+ (BOOL)cellularActive;
+ (BOOL)preferLAN;
+ (void)markLANFailed;
+ (NSString *)pathLabel;
+ (NSString *)routeLabel;

@end

NS_ASSUME_NONNULL_END
