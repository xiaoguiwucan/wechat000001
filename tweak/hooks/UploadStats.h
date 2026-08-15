#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXIngestUploadStats : NSObject

+ (void)recordBytes:(NSUInteger)bytes
               type:(nullable NSString *)type
           chatName:(nullable NSString *)chatName
            viaWifi:(BOOL)viaWifi;

+ (NSDictionary<NSString *, id> *)today;
+ (NSDictionary<NSString *, id> *)week;
+ (NSDictionary<NSString *, id> *)year;
+ (NSString *)prettyBytes:(unsigned long long)bytes;
+ (double)currentSpeedBps;
+ (NSArray<NSString *> *)activeChats;
+ (void)noteActiveChat:(nullable NSString *)chatName;
+ (void)noteFinishedChat:(nullable NSString *)chatName;

@end

NS_ASSUME_NONNULL_END
