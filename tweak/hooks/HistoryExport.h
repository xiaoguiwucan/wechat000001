#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXIngestHistoryExport : NSObject

+ (void)scanWithCompletion:(void (^)(NSDictionary<NSString *, id> *report))completion;
+ (void)startExport;
+ (void)startExportWipingRemote:(BOOL)wipe;
+ (void)stopExport;
+ (void)resumeIfNeeded;
+ (BOOL)isRunning;
+ (BOOL)isScanning;
+ (NSDictionary<NSString *, id> *)lastScan;
+ (NSDictionary<NSString *, id> *)progress;
+ (NSString *)progressLine;
+ (NSString *)destinationPath;
+ (float)fraction;

@end

NS_ASSUME_NONNULL_END
