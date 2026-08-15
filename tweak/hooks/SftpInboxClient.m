// WeChatIngest — tweak/hooks/SftpInboxClient.m (todo-12 deliverable).
//
// SFTP drop into `wechat-ingest/inbox/` over the EXISTING SSH session (libssh2
// SSHForwarder pattern). One SSH connection multiplexes this SFTP channel
// (ingest) with the 18790 local forward (todo-13 reply pipe). Ingest never
// uses HTTP to 18789, and this file never calls sendMsg:toUser: or any reply
// mechanism — the drop path is strictly putData:toPath: into inbox/.

#import "SftpInboxClient.h"
#import "Libssh2SftpChannel.h"
#import "NetworkPath.h"
#import "UploadStats.h"
#import "UploadHUD.h"

#import "../Settings.h"

#import <dispatch/dispatch.h>
#import <stdatomic.h>
#import <unistd.h>

static NSString * const kWXIngestSftpErrorDomain = @"com.zkx.wechat.ingest.sftp";
static NSString * const kWXIngestDefaultRemoteInbox = @"/vol1/1000/iphone微信蒸馏上传数据/inbox";

@implementation WeChatIngestSftpInboxClient {
    NSString *_host;
    NSInteger _port;
    NSString *_username;
    NSString *_password;
    NSString *_desiredHost;
    NSInteger _desiredPort;
    NSString *_desiredUser;
    NSString *_desiredPass;
    NSString *_remoteInboxPath;
    dispatch_queue_t _queue;
    atomic_int _pending;
}

+ (instancetype)sharedClientWithDefaults {
    static WeChatIngestSftpInboxClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *inbox = [WXIngestSettings inboxPath];
        if (inbox.length == 0) {
            inbox = kWXIngestDefaultRemoteInbox;
        }
        shared = [[WeChatIngestSftpInboxClient alloc] initWithSSHHost:[WXIngestSettings sshHost]
                                                              sshPort:[WXIngestSettings sshPort]
                                                             username:[WXIngestSettings sshUser]
                                                             password:[WXIngestSettings sshPassword]
                                                     remoteInboxPath:inbox];
    });
    [shared captureDesiredEndpoint];
    return shared;
}

- (void)captureDesiredEndpoint {
    NSString *host = [WXIngestSettings sshHost];
    NSInteger port = [WXIngestSettings sshPort];
    NSString *user = [WXIngestSettings sshUser];
    NSString *pass = [WXIngestSettings sshPassword];
    @synchronized (self) {
        _desiredHost = [host copy];
        _desiredPort = port;
        _desiredUser = [user copy];
        _desiredPass = [pass copy];
    }
}

- (void)applyCurrentEndpoint {
    [self captureDesiredEndpoint];
    dispatch_async(_queue, ^{
        [self reconnectOnQueue];
    });
}

- (void)reconnectOnQueue {
    NSString *host = nil;
    NSInteger port = 0;
    NSString *user = nil;
    NSString *pass = nil;
    @synchronized (self) {
        host = [_desiredHost copy] ?: [_host copy];
        port = _desiredPort > 0 ? _desiredPort : _port;
        user = [_desiredUser copy] ?: [_username copy];
        pass = [_desiredPass copy] ?: [_password copy];
    }
    BOOL same = [self.host isEqualToString:host ?: @""] &&
                self.port == port &&
                [self.username isEqualToString:user ?: @""] &&
                [self.password isEqualToString:pass ?: @""] &&
                self.channel != nil;
    if (same) {
        return;
    }
    id<WXIngestSftpPutting> old = self.channel;
    self.channel = (host.length > 0 && user.length > 0)
        ? [[WXIngestLibssh2SftpChannel alloc] initWithHost:host
                                                      port:port
                                                  username:user
                                                  password:pass]
        : nil;
    @synchronized (self) {
        _host = [host copy];
        _port = port;
        _username = [user copy];
        _password = [pass copy];
    }
    [old close];
}

- (instancetype)initWithSSHHost:(NSString *)host
                        sshPort:(NSInteger)port
                       username:(NSString *)username
                       password:(NSString *)password
               remoteInboxPath:(NSString *)remoteInboxPath {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _password = [password copy];
        _desiredHost = [host copy];
        _desiredPort = port;
        _desiredUser = [username copy];
        _desiredPass = [password copy];
        _remoteInboxPath = [remoteInboxPath copy];
        _maxAttempts = 3;
        _retryDelay = 1.0;
        _queue = dispatch_queue_create("com.zkx.wechat.ingest.sftp", DISPATCH_QUEUE_SERIAL);
        if (host.length > 0 && username.length > 0) {
            self.channel = [[WXIngestLibssh2SftpChannel alloc] initWithHost:host
                                                                       port:port
                                                                   username:username
                                                                   password:password];
        }
    }
    return self;
}

- (NSString *)remotePathForStem:(NSString *)stem suffix:(NSString *)suffix {
    return [_remoteInboxPath stringByAppendingPathComponent:[stem stringByAppendingString:suffix]];
}

- (void)enqueueEvent:(NSDictionary<NSString *, id> *)event
           mediaData:(nullable NSData *)mediaData
         mediaSuffix:(nullable NSString *)mediaSuffix {
    NSData *payload = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    if (payload == nil) {
        NSLog(@"[WeChatIngest] SFTP drop skipped — event not JSON-serializable");
        return;
    }
    NSString *stem = [[NSUUID UUID] UUIDString];
    NSData *mediaOrNil = mediaData;
    NSString *mediaSuffixOrBin = mediaSuffix ?: @".bin";
    NSString *jsonPath = [self remotePathForStem:stem suffix:@".json"];
    NSString *mediaPath = mediaOrNil ? [self remotePathForStem:stem suffix:mediaSuffixOrBin] : nil;

    atomic_fetch_add(&_pending, 1);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSUInteger sent = 0;
        BOOL wifi = [WXIngestNetwork wifiActive];
        if (mediaOrNil) {
            if ([strongSelf putWithRetry:mediaOrNil toPath:mediaPath]) {
                sent += mediaOrNil.length;
            }
        }
        BOOL jsonOk = [strongSelf putWithRetry:payload toPath:jsonPath];
        if (jsonOk) {
            sent += payload.length;
            NSString *type = [event[@"msg_type"] isKindOfClass:[NSString class]] ? event[@"msg_type"] : @"other";
            NSString *chat = [event[@"chat_name"] isKindOfClass:[NSString class]] ? event[@"chat_name"] : nil;
            if (chat.length == 0 && [event[@"chat_id"] isKindOfClass:[NSString class]]) {
                chat = event[@"chat_id"];
            }
            [WXIngestUploadStats recordBytes:sent type:type chatName:chat viaWifi:wifi];
            [WXIngestUploadStats noteActiveChat:chat];
            dispatch_async(dispatch_get_main_queue(), ^{
                [WXIngestUploadHUD refresh];
            });
        } else {
            [strongSelf persistLocally:payload media:mediaOrNil suffix:mediaSuffixOrBin stem:stem];
        }
        atomic_fetch_sub(&strongSelf->_pending, 1);
    });
}

- (NSUInteger)pendingCount {
    int n = atomic_load(&_pending);
    return n > 0 ? (NSUInteger)n : 0;
}

- (void)enqueueJSONObject:(NSDictionary<NSString *, id> *)object {
    if (object.count == 0) {
        return;
    }
    NSData *payload = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (payload == nil) {
        return;
    }
    NSString *path = [self remotePathForStem:[[NSUUID UUID] UUIDString] suffix:@".json"];
    atomic_fetch_add(&_pending, 1);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf putWithRetry:payload toPath:path];
        atomic_fetch_sub(&strongSelf->_pending, 1);
    });
}

- (void)enqueueLocalFile:(NSString *)localPath remoteRelativePath:(NSString *)relativePath {
    if (localPath.length == 0 || relativePath.length == 0 || [relativePath containsString:@".."]) {
        return;
    }
    NSString *remote = [_remoteInboxPath stringByAppendingPathComponent:relativePath];
    atomic_fetch_add(&_pending, 1);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf putFileWithRetry:localPath toPath:remote];
        atomic_fetch_sub(&strongSelf->_pending, 1);
    });
}

- (NSString *)localQueueDir {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"WeChatIngest/queue"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

- (void)persistLocally:(NSData *)payload
                 media:(NSData *)media
                suffix:(NSString *)suffix
                  stem:(NSString *)stem {
    NSString *dir = [self localQueueDir];
    [payload writeToFile:[dir stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]]
              atomically:YES];
    if (media.length > 0) {
        [media writeToFile:[dir stringByAppendingPathComponent:[stem stringByAppendingString:suffix]]
                atomically:YES];
    }
    NSLog(@"[WeChatIngest] SFTP failed — queued locally %@", stem);
}

- (NSString *)remoteRootPath {
    NSString *inbox = _remoteInboxPath.length ? _remoteInboxPath : kWXIngestDefaultRemoteInbox;
    return [inbox stringByDeletingLastPathComponent];
}

- (void)enqueueDebugLog:(NSData *)data {
    if (data.length == 0) {
        return;
    }
    NSString *latest = [[self remoteRootPath] stringByAppendingPathComponent:@"status/debug.log"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *archive = [[self remoteRootPath] stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"status/logs/debug-%@.log", stamp]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        BOOL okLatest = [weakSelf putWithRetry:data toPath:latest];
        BOOL okArch = [weakSelf putWithRetry:data toPath:archive];
        NSLog(@"[WeChatIngest] debug.log upload latest=%@ archive=%@",
              okLatest ? @"ok" : @"fail", okArch ? @"ok" : @"fail");
    });
}

- (void)enqueueStatus:(NSDictionary<NSString *, id> *)status {
    [self enqueueNamedJSON:status fileName:@"plugin.json"];
}

- (void)enqueueNamedJSON:(NSDictionary<NSString *, id> *)object fileName:(NSString *)fileName {
    if (object.count == 0 || fileName.length == 0 || [fileName containsString:@"/"]) {
        return;
    }
    NSData *payload = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:NULL];
    if (payload == nil) {
        return;
    }
    NSString *path = [[self remoteRootPath] stringByAppendingPathComponent:[@"status" stringByAppendingPathComponent:fileName]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf putWithRetry:payload toPath:path];
    });
}

- (void)fetchServerStatusWithCompletion:(void (^)(NSDictionary<NSString *, id> *status))completion {
    NSString *path = [[self remoteRootPath] stringByAppendingPathComponent:@"status/server.json"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        typeof(self) strongSelf = weakSelf;
        NSDictionary *obj = nil;
        [strongSelf reconnectOnQueue];
        id<WXIngestSftpPutting> channel = strongSelf.channel;
        if ([channel respondsToSelector:@selector(dataFromPath:error:)]) {
            NSError *error = nil;
            NSData *data = [channel dataFromPath:path error:&error];
            if (data.length) {
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([parsed isKindOfClass:[NSDictionary class]]) {
                    obj = parsed;
                }
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(obj);
            });
        }
    });
}

- (void)enqueueNameMap:(NSDictionary<NSString *, NSString *> *)nameMap {
    if (nameMap.count == 0) {
        return;
    }
    NSData *payload = [NSJSONSerialization dataWithJSONObject:nameMap options:0 error:NULL];
    if (payload == nil) {
        return;
    }
    NSString *path = [self.remoteInboxPath stringByAppendingPathComponent:@"names.json"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf putWithRetry:payload toPath:path];
    });
}

- (BOOL)putFileWithRetry:(NSString *)localPath toPath:(NSString *)path {
    [self reconnectOnQueue];
    id<WXIngestSftpPutting> channel = self.channel;
    if (channel == nil) {
        return NO;
    }
    if ([channel respondsToSelector:@selector(putFile:toPath:error:)]) {
        for (NSUInteger attempt = 1; attempt <= self.maxAttempts; attempt++) {
            NSError *error = nil;
            if ([channel putFile:localPath toPath:path error:&error]) {
                return YES;
            }
            NSLog(@"[WeChatIngest] SFTP putFile failed %@: %@ (attempt %lu/%lu)",
                  path, error.localizedDescription ?: @"unknown error",
                  (unsigned long)attempt, (unsigned long)self.maxAttempts);
            if (attempt < self.maxAttempts) {
                usleep((useconds_t)(self.retryDelay * 1000000.0));
            }
        }
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:localPath];
    if (data == nil) {
        return NO;
    }
    return [self putWithRetry:data toPath:path];
}

- (BOOL)putWithRetry:(NSData *)data toPath:(NSString *)path {
    [self reconnectOnQueue];
    id<WXIngestSftpPutting> channel = self.channel;
    if (channel == nil) {
        NSLog(@"[WeChatIngest] SFTP channel not configured — %@ not dropped", path);
        return NO;
    }
    for (NSUInteger attempt = 1; attempt <= self.maxAttempts; attempt++) {
        NSError *error = nil;
        if ([channel putData:data toPath:path error:&error]) {
            return YES;
        }
        NSLog(@"[WeChatIngest] SFTP put failed %@: %@ (attempt %lu/%lu)",
              path, error.localizedDescription ?: @"unknown error",
              (unsigned long)attempt, (unsigned long)self.maxAttempts);
        if ([WXIngestSettings usingLAN] && attempt == 1) {
            [WXIngestNetwork markLANFailed];
            [self captureDesiredEndpoint];
            [self reconnectOnQueue];
            channel = self.channel;
        }
        if (attempt < self.maxAttempts) {
            usleep((useconds_t)(self.retryDelay * 1000000.0));
        }
    }
    return NO;
}

@end
