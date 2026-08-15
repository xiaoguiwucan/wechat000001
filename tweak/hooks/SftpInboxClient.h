// WeChatIngest — tweak/hooks/SftpInboxClient.h (todo-12 deliverable).
//
// SFTP drop into `wechat-ingest/inbox/` over the EXISTING SSH session, shaped
// after PKC's libssh2 SSHForwarder (`initWithSSHHost:sshPort:username:password:`).
// ONE SSH connection multiplexes this SFTP channel (ingest) with the 18790
// local forward (todo-13 reply pipe). Ingest NEVER uses HTTP to 18789 and this
// class never calls sendMsg:toUser: / any reply machinery.
//
// Foundation-only: the actual byte transport is a swappable `WXIngestSftpPutting`
// channel (the device build wires PKC's libssh2 SFTP channel onto the existing
// SSH session); the host build compiles without libssh2.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One SFTP put on the existing SSH session (libssh2 SFTP channel seam).
/// Foundation-only protocol so the dylib compiles without libssh2 headers.
@protocol WXIngestSftpPutting <NSObject>
- (BOOL)putData:(NSData *)data toPath:(NSString *)remotePath error:(NSError * _Nullable * _Nullable)error;
- (void)close;
@optional
- (nullable NSData *)dataFromPath:(NSString *)remotePath error:(NSError * _Nullable * _Nullable)error;
- (BOOL)putFile:(NSString *)localPath toPath:(NSString *)remotePath error:(NSError * _Nullable * _Nullable)error;
@end

/// Serializes ingest events and SFTP-puts them into `<root>/inbox/<uuid>.json`
/// (+ optional media). Bounded retry on transport failure; never sends replies.
@interface WeChatIngestSftpInboxClient : NSObject

/// SSHForwarder-shaped initializer. `remoteInboxPath` is the remote inbox dir
/// (e.g. /root/.openclaw/wechat-ingest/inbox); no public port is opened here.
- (instancetype)initWithSSHHost:(NSString *)host
                        sshPort:(NSInteger)port
                       username:(NSString *)username
                       password:(NSString *)password
               remoteInboxPath:(NSString *)remoteInboxPath;

/// Shared client bound to the ingest settings suite (ingest.ssh.* keys).
+ (instancetype)sharedClientWithDefaults;

/// Copy current LAN/WAN endpoint and reconnect on the SFTP queue only.
/// Safe to call from any thread; never closes libssh2 on the main thread.
- (void)applyCurrentEndpoint;

/// Enqueue one mapped event: JSON -> inbox/<uuid>.json, optional media ->
/// inbox/<uuid><suffix>, both SFTP-put asynchronously with bounded retry.
/// Media is committed BEFORE the json (the json is the consumer's claim marker).
- (void)enqueueEvent:(NSDictionary<NSString *, id> *)event
           mediaData:(nullable NSData *)mediaData
         mediaSuffix:(nullable NSString *)mediaSuffix;

/// Upload `{chat_id: display_name}` as inbox/names.json so fnOS can rename folders.
- (void)enqueueNameMap:(NSDictionary<NSString *, NSString *> *)nameMap;

/// Write live plugin status to `<root>/status/plugin.json`.
- (void)enqueueStatus:(NSDictionary<NSString *, id> *)status;

/// Write a JSON object to `<root>/status/<fileName>`.
- (void)enqueueNamedJSON:(NSDictionary<NSString *, id> *)object fileName:(NSString *)fileName;

/// Write debug log text to `<root>/status/debug.log`.
- (void)enqueueDebugLog:(NSData *)data;

/// Read `<root>/status/server.json` written by the fnOS console.
- (void)fetchServerStatusWithCompletion:(void (^)(NSDictionary<NSString *, id> * _Nullable status))completion;

/// Swappable SFTP channel (tests inject a fake; device build injects libssh2).
@property(nonatomic, strong, nullable) id<WXIngestSftpPutting> channel;

/// SSHForwarder-shaped connection params (the device libssh2 channel is built
/// from these on the existing SSH session).
@property(nonatomic, copy, readonly) NSString *host;
@property(nonatomic, readonly) NSInteger port;
@property(nonatomic, copy, readonly) NSString *username;
@property(nonatomic, copy, readonly) NSString *password;
@property(nonatomic, copy, readonly) NSString *remoteInboxPath;

@property(nonatomic) NSUInteger maxAttempts;     // default 3
@property(nonatomic) NSTimeInterval retryDelay;  // default 1.0 s

/// In-flight SFTP event puts (not status/log). Export uses this as backpressure.
- (NSUInteger)pendingCount;

/// One JSON object as inbox/<uuid>.json (history batches, control cmds).
- (void)enqueueJSONObject:(NSDictionary<NSString *, id> *)object;

/// Stream a local file into inbox/<relativePath> without loading it all.
- (void)enqueueLocalFile:(NSString *)localPath remoteRelativePath:(NSString *)relativePath;

@end

NS_ASSUME_NONNULL_END
