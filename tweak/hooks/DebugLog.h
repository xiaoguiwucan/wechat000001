#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Append one debug line. Never logs passwords or full message bodies.
FOUNDATION_EXPORT void WeChatIngestDebugLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Current in-memory log (newest last). Capped.
FOUNDATION_EXPORT NSString *WeChatIngestDebugLogText(void);

/// Upload log to fnOS `status/debug.log` over the existing SFTP session.
FOUNDATION_EXPORT void WeChatIngestDebugLogFlushRemote(void);

FOUNDATION_EXPORT NSUInteger WeChatIngestDebugLogCount(void);

NS_ASSUME_NONNULL_END
