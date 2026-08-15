// WeChatIngest — substrate-free Theos skeleton targeting WeChat (com.tencent.xin).
//
// TODO-8 deliverable: a compilable arm64 dylib shell that TrollFools can inject
// into WeChat. This file intentionally implements NO message hooks yet — the
// AddMsg:MsgWrap: / AsyncOnPreAddMsg:MsgWrap: / HandleAppMsg:MsgWrap: swizzles
// are TODO-10 (tweak/hooks/MessageHooks.m). Here we only lay down:
//   - a constructor entry point (%ctor equivalent, via __attribute__),
//   - a plain ObjC runtime swizzle helper (objc/runtime.h, method_exchangeImplementations),
//   - a clearly marked hook-registration seam for TODO-10.
//
// Deliberately NOT imported: substrate.h, CydiaSubstrate, ElleKit, any
// jailbreak loader. This dylib is a raw ObjC-swizzle-only payload for
// TrollStore / TrollFools (non-jailbroken WeChat, bundle com.tencent.xin).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#import "hooks/MessageHooks.h"
#import "hooks/SettingsUI.h"
#import "hooks/Contacts.h"
#import "hooks/StatusSync.h"
#import "hooks/DebugLog.h"
#import "hooks/NetworkPath.h"
#import "hooks/UploadHUD.h"
#import "hooks/SftpInboxClient.h"

// ---------------------------------------------------------------------------
// Swizzle helper — the ONLY injection primitive used in this project.
// Exchanges the IMPs of two instance methods on a class via the plain ObjC
// runtime. Returns YES when both selectors were found and swapped.
// ---------------------------------------------------------------------------
static BOOL WeChatIngestSwizzleInstanceMethod(Class cls,
                                              SEL originalSelector,
                                              SEL replacementSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method replacementMethod = class_getInstanceMethod(cls, replacementSelector);
    if (originalMethod == NULL || replacementMethod == NULL) {
        return NO;
    }
    method_exchangeImplementations(originalMethod, replacementMethod);
    return YES;
}

// ---------------------------------------------------------------------------
// TODO-10 seam: register the real message hooks here.
// Selectors to swizzle on the host class CMessageMgr (per
// contracts/pkc-selectors.json, all confirmed present as runtime selector
// literals in the PKC sample dylib):
//   - AddMsg:MsgWrap:
//   - AsyncOnPreAddMsg:MsgWrap:
//   - HandleAppMsg:MsgWrap:
// Each swizzled implementation MUST forward to the original IMP first, then
// hand the CMessageWrap to the policy + ingest module. This skeleton keeps
// the list empty so the injected dylib is inert until TODO-10 lands.
// ---------------------------------------------------------------------------
static void WeChatIngestRegisterHooks(void) {
    WeChatIngestInstallMessageHooks();
    WeChatIngestInstallSettingsHook();
}

// ---------------------------------------------------------------------------
// Constructor — the substrate-free %ctor equivalent.
// Runs when the dylib is loaded into WeChat by TrollFools.
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void WeChatIngestInitializer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WeChatIngestInstallAlertBlocker();
        WeChatIngestDebugLog(@"dylib loaded 1.5.32");
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [WXIngestNetwork start];
                WeChatIngestInstallSettingsHook();
                [WXIngestUploadHUD start];
            } @catch (NSException *e) {
                NSLog(@"[WeChatIngest] settings hook failed: %@", e);
            }
        });
        [[NSNotificationCenter defaultCenter] addObserverForName:WXIngestNetworkDidChangeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(__unused NSNotification *note) {
            [[WeChatIngestSftpInboxClient sharedClientWithDefaults] applyCurrentEndpoint];
            dispatch_async(dispatch_get_main_queue(), ^{
                [WXIngestUploadHUD refresh];
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                WeChatIngestInstallMessageHooks();
            } @catch (NSException *e) {
                NSLog(@"[WeChatIngest] message hook failed: %@", e);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            WeChatIngestStartStatusLoop();
            [WXIngestContacts syncNamesToServer];
        });
    });
}
