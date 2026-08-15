#import "DebugLog.h"
#import "SftpInboxClient.h"
#import "../Settings.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

static const NSUInteger kWXDebugMaxLines = 2500;
static const NSUInteger kWXDebugMaxChars = 600000;

static NSMutableArray<NSString *> *WXDebugLines(void) {
    static NSMutableArray<NSString *> *lines = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = [NSMutableArray array];
    });
    return lines;
}

static NSString *WXDebugStamp(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [fmt stringFromDate:[NSDate date]];
}

void WeChatIngestDebugLog(NSString *format, ...) {
    if (format.length == 0) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (body.length > 900) {
        body = [[body substringToIndex:900] stringByAppendingString:@"…"];
    }
    NSString *line = [NSString stringWithFormat:@"%@ %@", WXDebugStamp(), body];
    NSMutableArray *lines = WXDebugLines();
    @synchronized (lines) {
        [lines addObject:line];
        while (lines.count > kWXDebugMaxLines) {
            [lines removeObjectAtIndex:0];
        }
    }
    NSLog(@"[WeChatIngest] %@", body);
}

NSString *WeChatIngestDebugLogText(void) {
    NSMutableArray *lines = WXDebugLines();
    NSArray *copy = nil;
    @synchronized (lines) {
        copy = [lines copy];
    }
    NSString *text = [copy componentsJoinedByString:@"\n"];
    if (text.length > kWXDebugMaxChars) {
        text = [text substringFromIndex:text.length - kWXDebugMaxChars];
    }
    return text ?: @"";
}

NSUInteger WeChatIngestDebugLogCount(void) {
    NSMutableArray *lines = WXDebugLines();
    @synchronized (lines) {
        return lines.count;
    }
}

void WeChatIngestDebugLogFlushRemote(void) {
    NSString *text = WeChatIngestDebugLogText();
    UIDevice *dev = [UIDevice currentDevice];
    NSString *header = [NSString stringWithFormat:
                        @"# wechat-ingest debug\n# device=%@ %@\n# ts=%ld\n# lines=%lu\n\n",
                        dev.name ?: @"",
                        [NSString stringWithFormat:@"%@ %@", dev.systemName, dev.systemVersion],
                        (long)[[NSDate date] timeIntervalSince1970],
                        (unsigned long)WeChatIngestDebugLogCount()];
    NSData *data = [[header stringByAppendingString:text] dataUsingEncoding:NSUTF8StringEncoding];
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueDebugLog:data];
}
