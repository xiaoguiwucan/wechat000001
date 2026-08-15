#import "HistoryExport.h"
#import "../Settings.h"

@implementation WXIngestHistoryExport
+ (void)scanWithCompletion:(void (^)(NSDictionary<NSString *, id> *report))completion {
    if (completion) {
        completion([NSDictionary dictionary]);
    }
}
+ (void)startExport {}
+ (void)stopExport {}
+ (void)resumeIfNeeded {}
+ (BOOL)isRunning { return NO; }
+ (BOOL)isScanning { return NO; }
+ (NSDictionary<NSString *, id> *)lastScan { return [NSDictionary dictionary]; }
+ (NSDictionary<NSString *, id> *)progress {
    return @{@"state": @"idle", @"chats_done": @0, @"chats_total": @0, @"msgs": @0};
}
+ (NSString *)progressLine { return @"当前是稳妥进微信版，导出引擎已卸下，避免闪退。"; }
+ (NSString *)destinationPath {
    NSString *inbox = [WXIngestSettings inboxPath];
    return inbox.length ? inbox : @"/data/inbox";
}
+ (float)fraction { return 0; }
@end
