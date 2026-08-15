#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WXIngestMediaReadyHandler)(id wrap);

/// Locate a WeChat service instance (MMContext / MMServiceCenter / shared*).
FOUNDATION_EXPORT id _Nullable WeChatIngestFindService(const char *className);

/// Pull image/voice/video bytes off a CMessageWrap (NSData, UIImage, disk path).
FOUNDATION_EXPORT NSData * _Nullable WeChatIngestExtractMediaData(
    id wrap,
    NSString *msgType,
    NSString * _Nullable * _Nullable outSuffix,
    NSString * _Nullable * _Nullable outDebug);

/// Reload the wrap from CMessageMgr after download (PKC: GetMsg:LocalID:).
FOUNDATION_EXPORT id _Nullable WeChatIngestRefreshWrap(id wrap);

/// Chat id for ingest: never the login wxid itself.
FOUNDATION_EXPORT NSString * _Nullable WeChatIngestConversationId(id wrap);

/// Build a CMessageWrap from sqlite Chat_* columns so media extract can
/// still resolve Documents/<hash>/Img|Audio|Video|OpenData/<md5>/<lid>.*
/// when GetMsg:LocalID: returns nil for a cold chat.
FOUNDATION_EXPORT id _Nullable WeChatIngestMakeBareWrap(NSString *chatId,
                                                        NSString *fromUser,
                                                        NSString *toUser,
                                                        unsigned int localId,
                                                        int type,
                                                        NSString * _Nullable content,
                                                        NSInteger createTime);

/// Ask WeChat to download the media body for this wrap.
FOUNDATION_EXPORT void WeChatIngestRequestMediaDownload(id wrap, NSString *msgType);

/// Hook download-complete + wrap setters so pending media is retried when bytes land.
FOUNDATION_EXPORT NSUInteger WeChatIngestInstallDownloadHooks(void);

FOUNDATION_EXPORT void WeChatIngestSetMediaReadyHandler(WXIngestMediaReadyHandler _Nullable handler);

NS_ASSUME_NONNULL_END
