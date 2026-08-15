#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void WeChatIngestStartStatusLoop(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *WeChatIngestPluginStatusSnapshot(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable WeChatIngestServerStatusCached(void);
FOUNDATION_EXPORT void WeChatIngestNoteEvent(BOOL uploaded, BOOL hadMedia, NSString * _Nullable error);

NS_ASSUME_NONNULL_END
