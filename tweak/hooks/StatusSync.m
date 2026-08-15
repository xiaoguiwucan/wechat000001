#import "StatusSync.h"
#import "SftpInboxClient.h"
#import "DebugLog.h"
#import "../Settings.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

static NSUInteger gUploaded = 0;
static NSUInteger gMediaFound = 0;
static NSUInteger gMediaMissed = 0;
static NSString *gLastError = @"";
static NSTimeInterval gLastUpload = 0;
static NSDictionary *gServerStatus = nil;
static dispatch_source_t gTimer = nil;

void WeChatIngestNoteEvent(BOOL uploaded, BOOL hadMedia, NSString *error) {
    @synchronized ([WXIngestSettings class]) {
        if (uploaded) {
            gUploaded += 1;
            gLastUpload = [[NSDate date] timeIntervalSince1970];
        }
        if (hadMedia) {
            gMediaFound += 1;
        } else if (error.length) {
            gMediaMissed += 1;
        }
        if (error.length) {
            gLastError = [error copy];
        }
    }
}

NSDictionary<NSString *, id> *WeChatIngestPluginStatusSnapshot(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSUInteger uploaded = 0, found = 0, missed = 0;
    NSTimeInterval last = 0;
    NSString *err = @"";
    @synchronized ([WXIngestSettings class]) {
        uploaded = gUploaded;
        found = gMediaFound;
        missed = gMediaMissed;
        last = gLastUpload;
        err = gLastError ?: @"";
    }
    UIDevice *dev = [UIDevice currentDevice];
    return @{
        @"role": @"plugin",
        @"version": @"1.5.31",
        @"debug_lines": @(WeChatIngestDebugLogCount()),
        @"ts": @((NSInteger)now),
        @"enabled": @([WXIngestSettings isEnabled]),
        @"upload_image": @([WXIngestSettings uploadImage]),
        @"upload_voice": @([WXIngestSettings uploadVoice]),
        @"upload_video": @([WXIngestSettings uploadVideo]),
        @"image_max_mb": @([WXIngestSettings imageMaxMB]),
        @"video_max_mb": @([WXIngestSettings videoMaxMB]),
        @"wifi_only_video": @([WXIngestSettings wifiOnlyMedia]),
        @"record_all_groups": @([WXIngestSettings recordAllGroups]),
        @"record_all_dms": @([WXIngestSettings recordAllDMs]),
        @"groups_selected": @([WXIngestSettings groupList].count),
        @"dms_selected": @([WXIngestSettings dmList].count),
        @"uploaded": @(uploaded),
        @"media_found": @(found),
        @"media_missed": @(missed),
        @"last_upload_ts": @((NSInteger)last),
        @"last_error": err,
        @"device": dev.name ?: @"",
        @"system": [NSString stringWithFormat:@"%@ %@", dev.systemName, dev.systemVersion],
    };
}

NSDictionary<NSString *, id> *WeChatIngestServerStatusCached(void) {
    @synchronized ([WXIngestSettings class]) {
        return [gServerStatus copy];
    }
}

static void WeChatIngestStatusTick(void) {
    NSDictionary *snap = WeChatIngestPluginStatusSnapshot();
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueStatus:snap];
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults]
        fetchServerStatusWithCompletion:^(NSDictionary *status) {
            if (status.count == 0) {
                return;
            }
            @synchronized ([WXIngestSettings class]) {
                gServerStatus = [status copy];
            }
        }];
}

void WeChatIngestStartStatusLoop(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                                  15 * NSEC_PER_SEC,
                                  2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(gTimer, ^{
            WeChatIngestStatusTick();
            WeChatIngestDebugLogFlushRemote();
        });
        WeChatIngestDebugLog(@"status loop start 1.5.31");
        dispatch_resume(gTimer);
    });
}
