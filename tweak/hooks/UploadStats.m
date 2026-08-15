#import "UploadStats.h"

#import <stdatomic.h>
#import <UIKit/UIKit.h>

static NSString * const kWXStatsKey = @"ingest.stats.days";
static const NSInteger kWXKeepDays = 400;

@implementation WXIngestUploadStats

static NSMutableDictionary *gDays;
static NSMutableArray<NSNumber *> *gSpeedTs;
static NSMutableArray<NSNumber *> *gSpeedBytes;
static NSMutableArray<NSString *> *gActive;
static dispatch_queue_t gQueue;

+ (void)initialize {
    if (self != [WXIngestUploadStats class]) {
        return;
    }
    gQueue = dispatch_queue_create("com.zkx.wechat.ingest.stats", DISPATCH_QUEUE_SERIAL);
    gSpeedTs = [NSMutableArray array];
    gSpeedBytes = [NSMutableArray array];
    gActive = [NSMutableArray array];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] objectForKey:kWXStatsKey];
    if (![saved isKindOfClass:[NSDictionary class]]) {
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"com.zkx.wechat.ingest"];
        saved = [suite objectForKey:kWXStatsKey];
    }
    gDays = [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

+ (NSString *)todayKey {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    fmt.dateFormat = @"yyyy-MM-dd";
    return [fmt stringFromDate:[NSDate date]];
}

+ (NSString *)canonicalType:(NSString *)type {
    NSString *t = [type lowercaseString] ?: @"";
    if ([t isEqualToString:@"image"] || [t isEqualToString:@"emoji"]) {
        return t;
    }
    if ([t isEqualToString:@"voice"] || [t isEqualToString:@"video"] || [t isEqualToString:@"file"] || [t isEqualToString:@"text"]) {
        return t;
    }
    return @"other";
}

+ (void)persistLocked {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"com.zkx.wechat.ingest"];
    [suite setObject:[gDays copy] forKey:kWXStatsKey];
}

+ (void)pruneLocked {
    if (gDays.count <= (NSUInteger)kWXKeepDays) {
        return;
    }
    NSArray *keys = [[gDays allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSInteger drop = (NSInteger)keys.count - kWXKeepDays;
    for (NSInteger i = 0; i < drop; i++) {
        [gDays removeObjectForKey:keys[(NSUInteger)i]];
    }
}

+ (void)recordBytes:(NSUInteger)bytes
               type:(NSString *)type
           chatName:(NSString *)chatName
            viaWifi:(BOOL)viaWifi {
    if (bytes == 0 && type.length == 0) {
        return;
    }
    dispatch_async(gQueue, ^{
        NSString *day = [self todayKey];
        NSMutableDictionary *row = [gDays[day] isKindOfClass:[NSDictionary class]]
            ? [gDays[day] mutableCopy]
            : [NSMutableDictionary dictionary];
        unsigned long long total = [row[@"bytes"] unsignedLongLongValue] + bytes;
        unsigned long long count = [row[@"count"] unsignedLongLongValue] + 1;
        row[@"bytes"] = @(total);
        row[@"count"] = @(count);
        NSString *bucket = [self canonicalType:type];
        unsigned long long typed = [row[bucket] unsignedLongLongValue] + bytes;
        row[bucket] = @(typed);
        NSString *net = viaWifi ? @"wifi" : @"wwan";
        row[net] = @([row[net] unsignedLongLongValue] + bytes);
        gDays[day] = row;
        [self pruneLocked];
        [self persistLocked];

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        [gSpeedTs addObject:@(now)];
        [gSpeedBytes addObject:@(bytes)];
        while (gSpeedTs.count > 0 && now - gSpeedTs.firstObject.doubleValue > 4.0) {
            [gSpeedTs removeObjectAtIndex:0];
            [gSpeedBytes removeObjectAtIndex:0];
        }
        if (chatName.length) {
            if (![gActive containsObject:chatName]) {
                [gActive addObject:chatName];
                if (gActive.count > 6) {
                    [gActive removeObjectAtIndex:0];
                }
            }
        }
    });
}

+ (void)noteActiveChat:(NSString *)chatName {
    if (chatName.length == 0) {
        return;
    }
    dispatch_async(gQueue, ^{
        if (![gActive containsObject:chatName]) {
            [gActive addObject:chatName];
        }
        if (gActive.count > 6) {
            [gActive removeObjectAtIndex:0];
        }
    });
}

+ (void)noteFinishedChat:(NSString *)chatName {
    if (chatName.length == 0) {
        return;
    }
    dispatch_async(gQueue, ^{
        [gActive removeObject:chatName];
    });
}

+ (NSArray<NSString *> *)activeChats {
    __block NSArray *copy = @[];
    dispatch_sync(gQueue, ^{
        copy = [gActive copy];
    });
    return copy;
}

+ (double)currentSpeedBps {
    __block double bps = 0;
    dispatch_sync(gQueue, ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        unsigned long long sum = 0;
        NSTimeInterval oldest = now;
        for (NSUInteger i = 0; i < gSpeedTs.count; i++) {
            NSTimeInterval ts = gSpeedTs[i].doubleValue;
            if (now - ts > 4.0) {
                continue;
            }
            if (ts < oldest) {
                oldest = ts;
            }
            sum += gSpeedBytes[i].unsignedLongLongValue;
        }
        NSTimeInterval span = MAX(0.4, now - oldest);
        bps = (double)sum / span;
    });
    return bps;
}

+ (NSDictionary<NSString *, id> *)sumFrom:(NSString *)fromKey to:(NSString *)toKey {
    __block NSDictionary *out = @{};
    dispatch_sync(gQueue, ^{
        unsigned long long bytes = 0, count = 0;
        unsigned long long text = 0, image = 0, voice = 0, video = 0, file = 0, emoji = 0, other = 0;
        unsigned long long wifi = 0, wwan = 0;
        for (NSString *key in gDays) {
            if (fromKey.length && [key compare:fromKey] == NSOrderedAscending) {
                continue;
            }
            if (toKey.length && [key compare:toKey] == NSOrderedDescending) {
                continue;
            }
            NSDictionary *row = gDays[key];
            if (![row isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            bytes += [row[@"bytes"] unsignedLongLongValue];
            count += [row[@"count"] unsignedLongLongValue];
            text += [row[@"text"] unsignedLongLongValue];
            image += [row[@"image"] unsignedLongLongValue];
            voice += [row[@"voice"] unsignedLongLongValue];
            video += [row[@"video"] unsignedLongLongValue];
            file += [row[@"file"] unsignedLongLongValue];
            emoji += [row[@"emoji"] unsignedLongLongValue];
            other += [row[@"other"] unsignedLongLongValue];
            wifi += [row[@"wifi"] unsignedLongLongValue];
            wwan += [row[@"wwan"] unsignedLongLongValue];
        }
        out = @{
            @"bytes": @(bytes),
            @"count": @(count),
            @"text": @(text),
            @"image": @(image),
            @"voice": @(voice),
            @"video": @(video),
            @"file": @(file),
            @"emoji": @(emoji),
            @"other": @(other),
            @"wifi": @(wifi),
            @"wwan": @(wwan),
        };
    });
    return out;
}

+ (NSString *)shiftDay:(NSString *)day by:(NSInteger)delta {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    fmt.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [fmt dateFromString:day] ?: [NSDate date];
    NSDate *shifted = [date dateByAddingTimeInterval:(NSTimeInterval)delta * 86400.0];
    return [fmt stringFromDate:shifted];
}

+ (NSDictionary<NSString *, id> *)today {
    NSString *key = [self todayKey];
    return [self sumFrom:key to:key];
}

+ (NSDictionary<NSString *, id> *)week {
    NSString *end = [self todayKey];
    return [self sumFrom:[self shiftDay:end by:-6] to:end];
}

+ (NSDictionary<NSString *, id> *)year {
    NSString *end = [self todayKey];
    return [self sumFrom:[self shiftDay:end by:-364] to:end];
}

+ (NSString *)prettyBytes:(unsigned long long)bytes {
    if (bytes < 1024) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    }
    double kb = bytes / 1024.0;
    if (kb < 1024) {
        return [NSString stringWithFormat:@"%.1f KB", kb];
    }
    double mb = kb / 1024.0;
    if (mb < 1024) {
        return [NSString stringWithFormat:@"%.2f MB", mb];
    }
    return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
}

@end
