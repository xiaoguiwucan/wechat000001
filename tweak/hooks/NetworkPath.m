#import "NetworkPath.h"
#import "../Settings.h"

#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <stdatomic.h>
#import <string.h>
#import <UIKit/UIKit.h>

NSString * const WXIngestNetworkDidChangeNotification = @"WXIngestNetworkDidChange";

@implementation WXIngestNetwork

static BOOL gWifi = NO;
static BOOL gCell = NO;
static BOOL gSeenWifi = NO;
static BOOL gSeenCell = NO;
static BOOL gForceWan = NO;
static BOOL gStarted = NO;
static NSTimeInterval gStableSince = 0;
static dispatch_source_t gTimer = NULL;

+ (void)scanWifi:(BOOL *)wifi cell:(BOOL *)cell {
    BOOL hasWifi = NO;
    BOOL hasCell = NO;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        if (wifi) {
            *wifi = gWifi;
        }
        if (cell) {
            *cell = gCell;
        }
        return;
    }
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_name == NULL) {
            continue;
        }
        if ((ifa->ifa_flags & IFF_UP) == 0 || (ifa->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        if (ifa->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        const char *name = ifa->ifa_name;
        if (strcmp(name, "en0") == 0) {
            hasWifi = YES;
        } else if (strncmp(name, "pdp_ip", 6) == 0) {
            hasCell = YES;
        }
    }
    freeifaddrs(list);
    if (wifi) {
        *wifi = hasWifi;
    }
    if (cell) {
        *cell = hasCell;
    }
}

+ (void)tick {
    BOOL wifi = NO;
    BOOL cell = NO;
    [self scanWifi:&wifi cell:&cell];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (wifi != gSeenWifi || cell != gSeenCell || !gStarted) {
        gSeenWifi = wifi;
        gSeenCell = cell;
        gStableSince = now;
        if (!gStarted) {
            gWifi = wifi;
            gCell = cell;
            gStarted = YES;
        }
        return;
    }
    if (now - gStableSince < 1.6) {
        return;
    }
    if (wifi == gWifi && cell == gCell) {
        return;
    }
    gWifi = wifi;
    gCell = cell;
    gForceWan = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:WXIngestNetworkDidChangeNotification
                                                            object:nil];
    });
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self tick];
        dispatch_queue_t queue = dispatch_queue_create("com.zkx.wechat.ingest.net", DISPATCH_QUEUE_SERIAL);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(gTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC,
                                  200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{
            [WXIngestNetwork tick];
        });
        dispatch_resume(gTimer);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(__unused NSNotification *note) {
            dispatch_async(queue, ^{
                [WXIngestNetwork tick];
            });
        }];
    });
}

+ (BOOL)wifiActive {
    return gWifi;
}

+ (BOOL)cellularActive {
    return gCell;
}

+ (BOOL)preferLAN {
    if (![WXIngestSettings autoSwitchNetwork]) {
        return NO;
    }
    if (!gWifi) {
        return NO;
    }
    return !gForceWan;
}

+ (void)markLANFailed {
    if (gWifi && [WXIngestSettings autoSwitchNetwork]) {
        gForceWan = YES;
    }
}

+ (NSString *)pathLabel {
    if ([self wifiActive]) {
        return @"Wi-Fi";
    }
    if ([self cellularActive]) {
        return @"蜂窝数据";
    }
    return @"离线";
}

+ (NSString *)routeLabel {
    if (![WXIngestSettings autoSwitchNetwork]) {
        return @"手动";
    }
    return [self preferLAN] ? @"内网" : @"公网";
}

@end
