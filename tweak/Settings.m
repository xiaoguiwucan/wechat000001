// WeChatIngest — settings implementation (TODO-9).
//
// Every persisted value lives in the NSUserDefaults suite com.zkx.wechat.ingest
// under OUR key names (see Settings.h). PKC's pkcOpenClaw* keys are never
// written here: if PKC is also installed, its defaults stay untouched and the
// two tweaks do not fight over state.

#import "Settings.h"
#import "hooks/NetworkPath.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

NSString * const WXIngestDefaultsSuite = @"com.zkx.wechat.ingest";

NSString * const WXIngestKeyEnable = @"ingest.enable";
NSString * const WXIngestKeySSHHost = @"ingest.ssh.host";
NSString * const WXIngestKeySSHPort = @"ingest.ssh.port";
NSString * const WXIngestKeySSHUser = @"ingest.ssh.user";
NSString * const WXIngestKeySSHPassword = @"ingest.ssh.password";
NSString * const WXIngestKeyGatewayPort = @"ingest.gateway.port";
NSString * const WXIngestKeyToken = @"ingest.token";
NSString * const WXIngestKeyCommandPrefix = @"ingest.command.prefix";
NSString * const WXIngestKeyGroupList = @"ingest.groups";
NSString * const WXIngestKeyDMList = @"ingest.dms";
NSString * const WXIngestKeyRecordAllGroups = @"ingest.record_all_groups";
NSString * const WXIngestKeyRecordAllDMs = @"ingest.record_all_dms";
NSString * const WXIngestKeyGroupExclude = @"ingest.group_exclude";
NSString * const WXIngestKeyDMExclude = @"ingest.dm_exclude";
NSString * const WXIngestKeyInboxPath = @"ingest.inbox.path";
NSString * const WXIngestKeyWifiOnlyMedia = @"ingest.media.wifi_only";
NSString * const WXIngestKeyCollectOfficials = @"ingest.collect_officials";
NSString * const WXIngestKeyUploadImage = @"ingest.media.upload_image";
NSString * const WXIngestKeyUploadVoice = @"ingest.media.upload_voice";
NSString * const WXIngestKeyUploadVideo = @"ingest.media.upload_video";
NSString * const WXIngestKeyImageMaxMB = @"ingest.media.image_max_mb";
NSString * const WXIngestKeyVideoMaxMB = @"ingest.media.video_max_mb";
NSString * const WXIngestKeyAutoSwitch = @"ingest.net.auto";
NSString * const WXIngestKeyLANHost = @"ingest.net.lan_host";
NSString * const WXIngestKeyLANPort = @"ingest.net.lan_port";
NSString * const WXIngestKeyWANHost = @"ingest.net.wan_host";
NSString * const WXIngestKeyWANPort = @"ingest.net.wan_port";
NSString * const WXIngestKeyHudEnabled = @"ingest.hud.enabled";
NSString * const WXIngestKeyHudHidden = @"ingest.hud.hidden";
NSString * const WXIngestKeyHudFrame = @"ingest.hud.frame";
static NSString * const WXIngestKeyLastSSHOK = @"ingest.ssh.last_ok";
static NSString * const WXIngestKeyLastSSHMsg = @"ingest.ssh.last_msg";

NSInteger const WXIngestDefaultGatewayPort = 18790;

static NSString * const kWXIngestErrorDomain = @"com.zkx.wechat.ingest.test";
static const NSTimeInterval kWXIngestTestTimeout = 15.0;

typedef NS_ENUM(NSInteger, WXIngestProbeError) {
    WXIngestProbeErrorInvalidInput = 1,
    WXIngestProbeErrorResolve = 2,
    WXIngestProbeErrorConnect = 3,
};

/// Non-blocking TCP connect probe. Returns YES when a connection to
/// host:port succeeds within `timeout` seconds.
static BOOL WXIngestProbeTCP(NSString *host,
                             NSInteger port,
                             NSTimeInterval timeout,
                             NSError **outError) {
    if (host.length == 0 || port <= 0 || port > 65535) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWXIngestErrorDomain
                                            code:WXIngestProbeErrorInvalidInput
                                        userInfo:@{NSLocalizedDescriptionKey: @"invalid host or port"}];
        }
        return NO;
    }

    char portC[8];
    snprintf(portC, sizeof(portC), "%ld", (long)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *addresses = NULL;
    int rc = getaddrinfo(host.UTF8String, portC, &hints, &addresses);
    if (rc != 0 || addresses == NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWXIngestErrorDomain
                                            code:WXIngestProbeErrorResolve
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:gai_strerror(rc)]}];
        }
        return NO;
    }

    // Cellular often returns IPv6 first; prefer IPv4 then fall back.
    struct addrinfo *ordered[32];
    int n = 0;
    for (struct addrinfo *ai = addresses; ai != NULL && n < 32; ai = ai->ai_next) {
        if (ai->ai_family == AF_INET) {
            ordered[n++] = ai;
        }
    }
    for (struct addrinfo *ai = addresses; ai != NULL && n < 32; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET) {
            ordered[n++] = ai;
        }
    }

    BOOL connected = NO;
    int fd = -1;
    for (int i = 0; i < n; i++) {
        struct addrinfo *ai = ordered[i];
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int result = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (result == 0) {
            connected = YES;
            break;
        }
        if (errno == EINPROGRESS) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(fd, &writeSet);
            struct timeval tv;
            tv.tv_sec = (time_t)timeout;
            tv.tv_usec = (suseconds_t)((timeout - tv.tv_sec) * 1000000.0);
            int selected = select(fd + 1, NULL, &writeSet, NULL, &tv);
            if (selected > 0) {
                int socketError = 0;
                socklen_t len = sizeof(socketError);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &len);
                if (socketError == 0) {
                    connected = YES;
                    break;
                }
            }
        }
        close(fd);
        fd = -1;
    }

    freeaddrinfo(addresses);
    if (fd >= 0) {
        close(fd);
    }

    if (!connected && outError) {
        *outError = [NSError errorWithDomain:kWXIngestErrorDomain
                                        code:WXIngestProbeErrorConnect
                                    userInfo:@{NSLocalizedDescriptionKey: @"connection failed or timed out"}];
    }
    return connected;
}

@implementation WXIngestSettings

+ (NSUserDefaults *)sharedDefaults {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:WXIngestDefaultsSuite];
        // In-memory defaults only — they are not persisted, so absent keys
        // still return sane values without touching PKC state.
        [defaults registerDefaults:@{
            WXIngestKeyEnable: @NO,
            WXIngestKeySSHHost: @"",
            WXIngestKeySSHPort: @22,
            WXIngestKeySSHUser: @"",
            WXIngestKeyGatewayPort: @(WXIngestDefaultGatewayPort),
            WXIngestKeyCommandPrefix: @"/",
            WXIngestKeyRecordAllGroups: @NO,
            WXIngestKeyRecordAllDMs: @NO,
            WXIngestKeyInboxPath: @"",
            WXIngestKeyWifiOnlyMedia: @YES,
            WXIngestKeyCollectOfficials: @NO,
            WXIngestKeyUploadImage: @YES,
            WXIngestKeyUploadVoice: @YES,
            WXIngestKeyUploadVideo: @YES,
            WXIngestKeyImageMaxMB: @20,
            WXIngestKeyVideoMaxMB: @50,
            WXIngestKeyAutoSwitch: @YES,
            WXIngestKeyLANHost: @"",
            WXIngestKeyLANPort: @22,
            WXIngestKeyWANHost: @"",
            WXIngestKeyWANPort: @22,
            WXIngestKeyHudEnabled: @YES,
            WXIngestKeyHudHidden: @NO,
        }];
        NSString *host = [defaults stringForKey:WXIngestKeySSHHost] ?: @"";
        NSString *low = host.lowercaseString;
        BOOL privateNet = [low hasPrefix:@"192.168."] || [low hasPrefix:@"10."] ||
                          [low hasPrefix:@"172.16."] || [low hasPrefix:@"172.17."] ||
                          [low hasPrefix:@"172.18."] || [low hasPrefix:@"127."];
        NSInteger port = [defaults integerForKey:WXIngestKeySSHPort];
        if (host.length && !privateNet && [[defaults stringForKey:WXIngestKeyWANHost] length] == 0) {
            [defaults setObject:host forKey:WXIngestKeyWANHost];
            if (port > 0) {
                [defaults setInteger:port forKey:WXIngestKeyWANPort];
            }
        } else if (host.length && privateNet && [[defaults stringForKey:WXIngestKeyLANHost] length] == 0) {
            [defaults setObject:host forKey:WXIngestKeyLANHost];
            if (port > 0) {
                [defaults setInteger:port forKey:WXIngestKeyLANPort];
            }
        }
        if ([defaults integerForKey:WXIngestKeyLANPort] <= 0) {
            [defaults setInteger:22 forKey:WXIngestKeyLANPort];
        }
        if ([defaults integerForKey:WXIngestKeyWANPort] <= 0) {
            [defaults setInteger:22 forKey:WXIngestKeyWANPort];
        }
        [defaults synchronize];
    });
    return defaults;
}

#pragma mark - enable

+ (BOOL)isEnabled {
    return [[self sharedDefaults] boolForKey:WXIngestKeyEnable];
}

+ (void)setEnabled:(BOOL)enabled {
    [[self sharedDefaults] setBool:enabled forKey:WXIngestKeyEnable];
}

#pragma mark - SSH

+ (NSString *)sshHost {
    if ([self autoSwitchNetwork]) {
        return [self usingLAN] ? [self lanHost] : [self wanHost];
    }
    NSString *host = [[self sharedDefaults] stringForKey:WXIngestKeySSHHost];
    return host.length ? host : [self lanHost];
}

+ (void)setSshHost:(NSString *)host {
    [[self sharedDefaults] setObject:host forKey:WXIngestKeySSHHost];
}

+ (NSInteger)sshPort {
    if ([self autoSwitchNetwork]) {
        return [self usingLAN] ? [self lanPort] : [self wanPort];
    }
    NSInteger port = [[self sharedDefaults] integerForKey:WXIngestKeySSHPort];
    return port > 0 ? port : [self lanPort];
}

+ (void)setSshPort:(NSInteger)port {
    [[self sharedDefaults] setInteger:port forKey:WXIngestKeySSHPort];
}

+ (NSString *)sshUser {
    return [[self sharedDefaults] stringForKey:WXIngestKeySSHUser] ?: @"";
}

+ (void)setSshUser:(NSString *)user {
    [[self sharedDefaults] setObject:user forKey:WXIngestKeySSHUser];
}

+ (NSString *)sshPassword {
    return [[self sharedDefaults] stringForKey:WXIngestKeySSHPassword] ?: @"";
}

+ (void)setSshPassword:(NSString *)password {
    [[self sharedDefaults] setObject:password forKey:WXIngestKeySSHPassword];
}

#pragma mark - gateway / token / prefix

+ (NSInteger)gatewayPort {
    return [[self sharedDefaults] integerForKey:WXIngestKeyGatewayPort];
}

+ (void)setGatewayPort:(NSInteger)port {
    [[self sharedDefaults] setInteger:port forKey:WXIngestKeyGatewayPort];
}

+ (NSString *)token {
    return [[self sharedDefaults] stringForKey:WXIngestKeyToken] ?: @"";
}

+ (void)setToken:(NSString *)token {
    [[self sharedDefaults] setObject:token forKey:WXIngestKeyToken];
}

+ (NSString *)commandPrefix {
    return [[self sharedDefaults] stringForKey:WXIngestKeyCommandPrefix] ?: @"/";
}

+ (void)setCommandPrefix:(NSString *)prefix {
    [[self sharedDefaults] setObject:prefix forKey:WXIngestKeyCommandPrefix];
}

#pragma mark - lists

+ (NSArray<NSString *> *)groupList {
    return [[self sharedDefaults] stringArrayForKey:WXIngestKeyGroupList] ?: [NSArray array];
}

+ (void)setGroupList:(NSArray<NSString *> *)groups {
    [[self sharedDefaults] setObject:groups forKey:WXIngestKeyGroupList];
}

+ (NSArray<NSString *> *)dmList {
    return [[self sharedDefaults] stringArrayForKey:WXIngestKeyDMList] ?: [NSArray array];
}

+ (void)setDmList:(NSArray<NSString *> *)dms {
    [[self sharedDefaults] setObject:dms forKey:WXIngestKeyDMList];
}

+ (BOOL)recordAllGroups {
    return [[self sharedDefaults] boolForKey:WXIngestKeyRecordAllGroups];
}

+ (void)setRecordAllGroups:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyRecordAllGroups];
}

+ (BOOL)recordAllDMs {
    return [[self sharedDefaults] boolForKey:WXIngestKeyRecordAllDMs];
}

+ (void)setRecordAllDMs:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyRecordAllDMs];
}

+ (NSArray<NSString *> *)groupExclude {
    return [[self sharedDefaults] stringArrayForKey:WXIngestKeyGroupExclude] ?: [NSArray array];
}

+ (void)setGroupExclude:(NSArray<NSString *> *)groups {
    [[self sharedDefaults] setObject:groups forKey:WXIngestKeyGroupExclude];
}

+ (NSArray<NSString *> *)dmExclude {
    return [[self sharedDefaults] stringArrayForKey:WXIngestKeyDMExclude] ?: [NSArray array];
}

+ (void)setDmExclude:(NSArray<NSString *> *)dms {
    [[self sharedDefaults] setObject:dms forKey:WXIngestKeyDMExclude];
}

+ (NSString *)inboxPath {
    NSString *path = [[self sharedDefaults] stringForKey:WXIngestKeyInboxPath];
    return path.length > 0 ? path : @"";
}

+ (void)setInboxPath:(NSString *)path {
    [[self sharedDefaults] setObject:path forKey:WXIngestKeyInboxPath];
}

+ (BOOL)wifiOnlyMedia {
    return [[self sharedDefaults] boolForKey:WXIngestKeyWifiOnlyMedia];
}

+ (void)setWifiOnlyMedia:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyWifiOnlyMedia];
}

+ (BOOL)collectOfficials {
    return [[self sharedDefaults] boolForKey:WXIngestKeyCollectOfficials];
}

+ (void)setCollectOfficials:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyCollectOfficials];
}

+ (BOOL)uploadImage {
    return [[self sharedDefaults] boolForKey:WXIngestKeyUploadImage];
}

+ (void)setUploadImage:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyUploadImage];
}

+ (BOOL)uploadVoice {
    return [[self sharedDefaults] boolForKey:WXIngestKeyUploadVoice];
}

+ (void)setUploadVoice:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyUploadVoice];
}

+ (BOOL)uploadVideo {
    return [[self sharedDefaults] boolForKey:WXIngestKeyUploadVideo];
}

+ (void)setUploadVideo:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyUploadVideo];
}

+ (NSInteger)imageMaxMB {
    NSInteger mb = [[self sharedDefaults] integerForKey:WXIngestKeyImageMaxMB];
    return mb > 0 ? mb : 20;
}

+ (void)setImageMaxMB:(NSInteger)mb {
    [[self sharedDefaults] setInteger:mb > 0 ? mb : 20 forKey:WXIngestKeyImageMaxMB];
}

+ (NSInteger)videoMaxMB {
    NSInteger mb = [[self sharedDefaults] integerForKey:WXIngestKeyVideoMaxMB];
    return mb > 0 ? mb : 50;
}

+ (void)setVideoMaxMB:(NSInteger)mb {
    [[self sharedDefaults] setInteger:mb > 0 ? mb : 50 forKey:WXIngestKeyVideoMaxMB];
}

+ (BOOL)autoSwitchNetwork {
    return [[self sharedDefaults] boolForKey:WXIngestKeyAutoSwitch];
}

+ (void)setAutoSwitchNetwork:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyAutoSwitch];
}

+ (NSString *)lanHost {
    NSString *host = [[self sharedDefaults] stringForKey:WXIngestKeyLANHost];
    return host.length ? host : @"";
}

+ (void)setLanHost:(NSString *)host {
    [[self sharedDefaults] setObject:host forKey:WXIngestKeyLANHost];
}

+ (NSInteger)lanPort {
    NSInteger port = [[self sharedDefaults] integerForKey:WXIngestKeyLANPort];
    return port > 0 ? port : 22;
}

+ (void)setLanPort:(NSInteger)port {
    [[self sharedDefaults] setInteger:port > 0 ? port : 22 forKey:WXIngestKeyLANPort];
}

+ (NSString *)wanHost {
    NSString *host = [[self sharedDefaults] stringForKey:WXIngestKeyWANHost];
    return host.length ? host : @"";
}

+ (void)setWanHost:(NSString *)host {
    [[self sharedDefaults] setObject:host forKey:WXIngestKeyWANHost];
}

+ (NSInteger)wanPort {
    NSInteger port = [[self sharedDefaults] integerForKey:WXIngestKeyWANPort];
    return port > 0 ? port : 22;
}

+ (void)setWanPort:(NSInteger)port {
    [[self sharedDefaults] setInteger:port > 0 ? port : 22 forKey:WXIngestKeyWANPort];
}

+ (BOOL)usingLAN {
    return [WXIngestNetwork preferLAN];
}

+ (BOOL)hudEnabled {
    return [[self sharedDefaults] boolForKey:WXIngestKeyHudEnabled];
}

+ (void)setHudEnabled:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyHudEnabled];
}

+ (BOOL)hudHidden {
    return [[self sharedDefaults] boolForKey:WXIngestKeyHudHidden];
}

+ (void)setHudHidden:(BOOL)value {
    [[self sharedDefaults] setBool:value forKey:WXIngestKeyHudHidden];
}

+ (CGRect)hudFrame {
    NSString *raw = [[self sharedDefaults] stringForKey:WXIngestKeyHudFrame];
    NSArray *parts = [raw componentsSeparatedByString:@","];
    if (parts.count != 4) {
        return CGRectZero;
    }
    return CGRectMake([parts[0] doubleValue], [parts[1] doubleValue],
                      [parts[2] doubleValue], [parts[3] doubleValue]);
}

+ (void)setHudFrame:(CGRect)frame {
    NSString *raw = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                     frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
    [[self sharedDefaults] setObject:raw forKey:WXIngestKeyHudFrame];
}

+ (BOOL)lastSSHOK {
    return [[self sharedDefaults] boolForKey:WXIngestKeyLastSSHOK];
}

+ (NSString *)lastSSHMessage {
    return [[self sharedDefaults] stringForKey:WXIngestKeyLastSSHMsg] ?: @"";
}

+ (void)setLastSSHOK:(BOOL)ok message:(NSString *)message {
    [[self sharedDefaults] setBool:ok forKey:WXIngestKeyLastSSHOK];
    [[self sharedDefaults] setObject:message ?: @"" forKey:WXIngestKeyLastSSHMsg];
}

#pragma mark - addOpenClawSection shape

+ (NSArray<NSDictionary<NSString *, id> *> *)settingsSectionRows {
    return [self rowsForPage:@"main"];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)rowsForPage:(NSString *)page {
    NSMutableArray *flat = [NSMutableArray array];
    for (NSDictionary *section in [self sectionsForPage:page]) {
        NSArray *rows = section[@"rows"];
        if ([rows isKindOfClass:[NSArray class]]) {
            [flat addObjectsFromArray:rows];
        }
    }
    return flat;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)sectionsForPage:(NSString *)page {
    if ([page isEqualToString:@"connection"]) {
        NSString *now = [NSString stringWithFormat:@"%@ · %@  %@:%ld",
                         [WXIngestNetwork pathLabel],
                         [WXIngestNetwork routeLabel],
                         [self sshHost],
                         (long)[self sshPort]];
        return @[
            @{@"header": @"线路",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"status.route", @"title": @"正在使用", @"detail": now},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"status.ssh", @"title": @"SSH"},
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyAutoSwitch, @"title": @"Wi-Fi / 流量自动切换"},
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyHudEnabled, @"title": @"显示上传悬浮窗"},
                  @{@"kind": @(WXIngestRowKindButton), @"action": @"testConnection", @"title": @"测试当前线路"},
              ]},
            @{@"header": @"地址",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyLANHost, @"title": @"内网主机", @"placeholder": @"10.0.0.2"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyLANPort, @"title": @"内网端口", @"placeholder": @"22", @"keyboard": @"number"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyWANHost, @"title": @"公网主机", @"placeholder": @"nas.example.com"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyWANPort, @"title": @"公网端口", @"placeholder": @"22", @"keyboard": @"number"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeySSHUser, @"title": @"用户名", @"placeholder": @"sftpuser"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeySSHPassword, @"title": @"密码", @"placeholder": @"SSH 密码", @"secure": @YES},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyInboxPath, @"title": @"Inbox", @"placeholder": @"/data/inbox", @"stacked": @YES},
              ]},
        ];
    }
    if ([page isEqualToString:@"stats"]) {
        return @[
            @{@"header": @"用量",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today", @"title": @"今日"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.week", @"title": @"近 7 天"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.year", @"title": @"近一年"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.wifi", @"title": @"Wi-Fi"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.wwan", @"title": @"流量"},
              ]},
            @{@"header": @"今日分类",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.text", @"title": @"文字"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.image", @"title": @"图片"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.voice", @"title": @"语音"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.video", @"title": @"视频"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.file", @"title": @"文件"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"stats.today.emoji", @"title": @"表情"},
              ]},
            @{@"header": @"窗",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyHudEnabled, @"title": @"显示悬浮窗"},
                  @{@"kind": @(WXIngestRowKindButton), @"action": @"showHud", @"title": @"立即显示"},
              ]},
        ];
    }
    if ([page isEqualToString:@"record"]) {
        return @[
            @{@"header": @"范围",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyRecordAllGroups, @"title": @"全部群聊"},
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyRecordAllDMs, @"title": @"全部私聊"},
                  @{@"kind": @(WXIngestRowKindButton), @"action": @"pickGroups", @"title": @"选择群聊"},
                  @{@"kind": @(WXIngestRowKindButton), @"action": @"pickDMs", @"title": @"选择私聊"},
                  @{@"kind": @(WXIngestRowKindButton), @"action": @"syncNames", @"title": @"同步群名和备注"},
              ]},
        ];
    }
    if ([page isEqualToString:@"media"]) {
        return @[
            @{@"header": @"媒体",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyUploadImage, @"title": @"图片 / 表情"},
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyUploadVoice, @"title": @"语音"},
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyUploadVideo, @"title": @"视频 / 文件"},
                  @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyWifiOnlyMedia, @"title": @"仅 Wi-Fi 传视频"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyImageMaxMB, @"title": @"图片上限", @"placeholder": @"20", @"keyboard": @"number", @"suffix": @"MB"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyVideoMaxMB, @"title": @"视频上限", @"placeholder": @"50", @"keyboard": @"number", @"suffix": @"MB"},
              ]},
        ];
    }
    if ([page isEqualToString:@"advanced"]) {
        return @[
            @{@"header": @"当前 SSH",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"cfg.sshHost", @"title": @"主机"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"cfg.sshPort", @"title": @"端口"},
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"cfg.sshUser", @"title": @"账号"},
                  @{@"kind": @(WXIngestRowKindPage), @"page": @"connection", @"title": @"去改连接", @"detail": @""},
              ]},
            @{@"header": @"预留",
              @"rows": @[
                  @{@"kind": @(WXIngestRowKindInfo), @"key": @"status.debug", @"title": @"本地日志"},
                  @{@"kind": @(WXIngestRowKindButton), @"action": @"uploadDebug", @"title": @"上传调试日志"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyGatewayPort, @"title": @"本机端口", @"placeholder": @"18790", @"keyboard": @"number"},
                  @{@"kind": @(WXIngestRowKindTextField), @"key": WXIngestKeyToken, @"title": @"Token", @"placeholder": @"选填", @"secure": @YES},
              ]},
        ];
    }
    NSString *recordDetail = nil;
    if ([self recordAllGroups] && [self recordAllDMs]) {
        recordDetail = @"全部群和私聊";
    } else {
        recordDetail = [NSString stringWithFormat:@"群 %lu · 私聊 %lu",
                        (unsigned long)[self groupList].count,
                        (unsigned long)[self dmList].count];
    }
    return @[
        @{@"header": @"采集",
          @"rows": @[
              @{@"kind": @(WXIngestRowKindSwitch), @"key": WXIngestKeyEnable, @"title": @"启用采集"},
              @{@"kind": @(WXIngestRowKindPage), @"page": @"record", @"title": @"选择会话", @"detail": recordDetail},
              @{@"kind": @(WXIngestRowKindPage), @"page": @"media", @"title": @"图片语音视频", @"detail": @"原图"},
          ]},
        @{@"header": @"飞牛",
          @"rows": @[
              @{@"kind": @(WXIngestRowKindPage), @"page": @"connection", @"title": @"连接飞牛",
                @"detail": [NSString stringWithFormat:@"%@ · %@", [WXIngestNetwork pathLabel], [WXIngestNetwork routeLabel]]},
              @{@"kind": @(WXIngestRowKindPage), @"page": @"stats", @"title": @"流量统计", @"detail": @"今日 / 周 / 年"},
              @{@"kind": @(WXIngestRowKindButton), @"action": @"refreshStatus", @"title": @"刷新状态"},
          ]},
        @{@"header": @"更多",
          @"rows": @[
              @{@"kind": @(WXIngestRowKindPage), @"page": @"advanced", @"title": @"高级", @"detail": @""},
              @{@"kind": @(WXIngestRowKindInfo), @"key": @"status.plugin", @"title": @"插件"},
          ]},
    ];
}

#pragma mark - testOpenClaw shape

+ (void)testConnection {
    [self testConnectionWithCompletion:nil];
}

+ (void)testConnectionWithCompletion:(nullable void (^)(BOOL reachable, NSString * _Nullable message))completion {
    NSString *host = [self sshHost];
    NSInteger sshPort = [self sshPort];
    NSInteger gatewayPort = [self gatewayPort];

    void (^report)(BOOL, NSString *) = ^(BOOL reachable, NSString *message) {
        [self setLastSSHOK:reachable message:message ?: @""];
        if (completion == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(reachable, message);
        });
    };

    if (host.length == 0) {
        report(NO, @"SSH host is empty");
        return;
    }
    if (sshPort <= 0 || sshPort > 65535) {
        report(NO, @"SSH port out of range");
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *sshError = nil;
        BOOL sshReachable = WXIngestProbeTCP(host, sshPort, kWXIngestTestTimeout, &sshError);
        if (!sshReachable) {
            report(NO, [NSString stringWithFormat:@"SSH connect failed: %@",
                        sshError.localizedDescription ?: @"unknown error"]);
            return;
        }
        (void)gatewayPort;
        NSString *route = [self usingLAN] ? @"内网" : @"公网";
        report(YES, [NSString stringWithFormat:@"%@ SSH 可达 %@:%ld。媒体和消息走 SFTP。",
                     route, host, (long)sshPort]);
    });
}

@end
