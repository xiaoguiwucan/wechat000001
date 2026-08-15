#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXIngestContact : NSObject
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, assign) BOOL isGroup;
@property(nonatomic, assign) NSInteger lastLocalId;
@property(nonatomic, assign) NSInteger msgHint;
@end

@interface WXIngestContacts : NSObject
+ (NSArray<WXIngestContact *> *)groups;
+ (NSArray<WXIngestContact *> *)people;
+ (NSArray<WXIngestContact *> *)visibleSessions;
+ (NSArray<WXIngestContact *> *)contactsOfKind:(NSString *)kind;
+ (NSString *)displayNameForUsername:(NSString *)username;
+ (NSDictionary<NSString *, NSString *> *)nameMap;
+ (void)syncNamesToServer;
@end

NS_ASSUME_NONNULL_END
