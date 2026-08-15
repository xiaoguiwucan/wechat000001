// WeChatIngest — settings surface (TODO-9 deliverable).
//
// Shape-clones PKC's `addOpenClawSection` / `testOpenClaw` settings surface
// (see contracts/pkc-selectors.json) but persists ONLY to the NSUserDefaults
// suite `com.zkx.wechat.ingest` with our OWN key names. PKC's `pkcOpenClaw*`
// keys are deliberately NEVER written here, so both tweaks can stay installed
// without fighting over shared defaults state.
//
// Compiles with Foundation only (no WeChat headers, no UIKit), so the same
// source is exercised by the Theos build and by scripts/build-dylib.sh.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CGGeometry.h>

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults suite everything is persisted under.
FOUNDATION_EXPORT NSString * const WXIngestDefaultsSuite;          // com.zkx.wechat.ingest

/// Settings keys — every one is required by scripts/check-settings-keys.sh.
FOUNDATION_EXPORT NSString * const WXIngestKeyEnable;              // ingest.enable        (BOOL)
FOUNDATION_EXPORT NSString * const WXIngestKeySSHHost;             // ingest.ssh.host
FOUNDATION_EXPORT NSString * const WXIngestKeySSHPort;             // ingest.ssh.port       (default 22)
FOUNDATION_EXPORT NSString * const WXIngestKeySSHUser;             // ingest.ssh.user
FOUNDATION_EXPORT NSString * const WXIngestKeySSHPassword;         // ingest.ssh.password
FOUNDATION_EXPORT NSString * const WXIngestKeyGatewayPort;         // ingest.gateway.port   (default 18790)
FOUNDATION_EXPORT NSString * const WXIngestKeyToken;               // ingest.token
FOUNDATION_EXPORT NSString * const WXIngestKeyCommandPrefix;       // ingest.command.prefix (default "/")
FOUNDATION_EXPORT NSString * const WXIngestKeyGroupList;           // ingest.groups  (whitelist when record-all off)
FOUNDATION_EXPORT NSString * const WXIngestKeyDMList;              // ingest.dms     (whitelist when record-all off)
FOUNDATION_EXPORT NSString * const WXIngestKeyRecordAllGroups;     // ingest.record_all_groups (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyRecordAllDMs;        // ingest.record_all_dms    (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyGroupExclude;        // ingest.group_exclude
FOUNDATION_EXPORT NSString * const WXIngestKeyDMExclude;           // ingest.dm_exclude
FOUNDATION_EXPORT NSString * const WXIngestKeyInboxPath;           // ingest.inbox.path
FOUNDATION_EXPORT NSString * const WXIngestKeyWifiOnlyMedia;       // ingest.media.wifi_only (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyCollectOfficials;    // ingest.collect_officials (BOOL, default NO)
FOUNDATION_EXPORT NSString * const WXIngestKeyUploadImage;         // ingest.media.upload_image (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyUploadVoice;         // ingest.media.upload_voice (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyUploadVideo;         // ingest.media.upload_video (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyImageMaxMB;          // ingest.media.image_max_mb (default 20)
FOUNDATION_EXPORT NSString * const WXIngestKeyVideoMaxMB;          // ingest.media.video_max_mb (default 50)
FOUNDATION_EXPORT NSString * const WXIngestKeyAutoSwitch;          // ingest.net.auto (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyLANHost;             // ingest.net.lan_host
FOUNDATION_EXPORT NSString * const WXIngestKeyLANPort;             // ingest.net.lan_port (default 22)
FOUNDATION_EXPORT NSString * const WXIngestKeyWANHost;             // ingest.net.wan_host
FOUNDATION_EXPORT NSString * const WXIngestKeyWANPort;             // ingest.net.wan_port (default 31631)
FOUNDATION_EXPORT NSString * const WXIngestKeyHudEnabled;          // ingest.hud.enabled (BOOL, default YES)
FOUNDATION_EXPORT NSString * const WXIngestKeyHudHidden;           // ingest.hud.hidden (BOOL, default NO)
FOUNDATION_EXPORT NSString * const WXIngestKeyHudFrame;            // ingest.hud.frame

/// Gateway listen port default — localhost only, matches the fnOS reply pipe.
FOUNDATION_EXPORT NSInteger const WXIngestDefaultGatewayPort;      // 18790

/// Row kinds emitted by -[WXIngestSettings settingsSectionRows].
typedef NS_ENUM(NSInteger, WXIngestRowKind) {
    WXIngestRowKindSwitch = 1,
    WXIngestRowKindTextField = 2,
    WXIngestRowKindTextArea = 3,
    WXIngestRowKindButton = 4,
    WXIngestRowKindPage = 5,
    WXIngestRowKindInfo = 6,
};

@interface WXIngestSettings : NSObject

/// Shared defaults object bound to the com.zkx.wechat.ingest suite.
+ (NSUserDefaults *)sharedDefaults;

// --------------------------------------------------------------------------
// Persisted accessors — one per required key. Every write goes through
// [NSUserDefaults set*:forKey:] on the suite above; no PKC key is touched.
// --------------------------------------------------------------------------
+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;

+ (NSString *)sshHost;
+ (void)setSshHost:(NSString *)host;
+ (NSInteger)sshPort;
+ (void)setSshPort:(NSInteger)port;
+ (NSString *)sshUser;
+ (void)setSshUser:(NSString *)user;
+ (NSString *)sshPassword;
+ (void)setSshPassword:(NSString *)password;
+ (NSInteger)gatewayPort;   // defaults to WXIngestDefaultGatewayPort (18790)
+ (void)setGatewayPort:(NSInteger)port;
+ (NSString *)token;
+ (void)setToken:(NSString *)token;
+ (NSString *)commandPrefix;
+ (void)setCommandPrefix:(NSString *)prefix;
+ (NSArray<NSString *> *)groupList;
+ (void)setGroupList:(NSArray<NSString *> *)groups;
+ (NSArray<NSString *> *)dmList;
+ (void)setDmList:(NSArray<NSString *> *)dms;
+ (BOOL)recordAllGroups;
+ (void)setRecordAllGroups:(BOOL)value;
+ (BOOL)recordAllDMs;
+ (void)setRecordAllDMs:(BOOL)value;
+ (NSArray<NSString *> *)groupExclude;
+ (void)setGroupExclude:(NSArray<NSString *> *)groups;
+ (NSArray<NSString *> *)dmExclude;
+ (void)setDmExclude:(NSArray<NSString *> *)dms;
+ (NSString *)inboxPath;
+ (void)setInboxPath:(NSString *)path;
+ (BOOL)wifiOnlyMedia;
+ (void)setWifiOnlyMedia:(BOOL)value;
+ (BOOL)collectOfficials;
+ (void)setCollectOfficials:(BOOL)value;
+ (BOOL)uploadImage;
+ (void)setUploadImage:(BOOL)value;
+ (BOOL)uploadVoice;
+ (void)setUploadVoice:(BOOL)value;
+ (BOOL)uploadVideo;
+ (void)setUploadVideo:(BOOL)value;
+ (NSInteger)imageMaxMB;
+ (void)setImageMaxMB:(NSInteger)mb;
+ (NSInteger)videoMaxMB;
+ (void)setVideoMaxMB:(NSInteger)mb;
+ (BOOL)autoSwitchNetwork;
+ (void)setAutoSwitchNetwork:(BOOL)value;
+ (NSString *)lanHost;
+ (void)setLanHost:(NSString *)host;
+ (NSInteger)lanPort;
+ (void)setLanPort:(NSInteger)port;
+ (NSString *)wanHost;
+ (void)setWanHost:(NSString *)host;
+ (NSInteger)wanPort;
+ (void)setWanPort:(NSInteger)port;
+ (BOOL)usingLAN;
+ (BOOL)hudEnabled;
+ (void)setHudEnabled:(BOOL)value;
+ (BOOL)hudHidden;
+ (void)setHudHidden:(BOOL)value;
+ (CGRect)hudFrame;
+ (void)setHudFrame:(CGRect)frame;
+ (BOOL)lastSSHOK;
+ (NSString *)lastSSHMessage;
+ (void)setLastSSHOK:(BOOL)ok message:(NSString *)message;

// --------------------------------------------------------------------------
// addOpenClawSection shape — the settings section as data, so the caller can
// render it into WeChat's settings table without this file depending on
// WeChat headers. PKC builds these rows imperatively inside addOpenClawSection;
// we expose the same row set declaratively. The last row is the Test button
// (WXIngestRowKindButton, action "testConnection" — the testOpenClaw shape).
// --------------------------------------------------------------------------
+ (NSArray<NSDictionary<NSString *, id> *> *)settingsSectionRows;
+ (NSArray<NSDictionary<NSString *, id> *> *)rowsForPage:(NSString *)page;
+ (NSArray<NSDictionary<NSString *, id> *> *)sectionsForPage:(NSString *)page;

// --------------------------------------------------------------------------
// testOpenClaw shape — Test button hook. Async TCP probe of SSH host:port and
// the gateway port. completion (nil = main queue) receives reachability and a
// human-readable message. Never blocks the caller.
// --------------------------------------------------------------------------
+ (void)testConnection;
+ (void)testConnectionWithCompletion:(nullable void (^)(BOOL reachable, NSString * _Nullable message))completion;

@end

NS_ASSUME_NONNULL_END
