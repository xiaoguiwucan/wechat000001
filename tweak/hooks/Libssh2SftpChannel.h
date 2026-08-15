#import <Foundation/Foundation.h>
#import "SftpInboxClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface WXIngestLibssh2SftpChannel : NSObject <WXIngestSftpPutting>
- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    username:(NSString *)username
                    password:(NSString *)password;
@end

NS_ASSUME_NONNULL_END
