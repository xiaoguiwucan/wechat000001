#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXIngestUploadHUD : NSObject

+ (void)start;
+ (void)setVisible:(BOOL)visible;
+ (BOOL)isVisible;
+ (void)refresh;

@end

NS_ASSUME_NONNULL_END
