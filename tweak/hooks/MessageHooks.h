// WeChatIngest — tweak/hooks/MessageHooks.h (todo-10).
//
// Public surface of the CMessageMgr message hooks. The three swizzled
// selectors are the PKC-proven runtime selector literals from
// contracts/pkc-selectors.json:
//   - AddMsg:MsgWrap:
//   - AsyncOnPreAddMsg:MsgWrap:
//   - HandleAppMsg:MsgWrap:
//
// Each hook forwards to the original IMP first (never skips it), then hands
// the CMessageWrap's five capture fields (m_uiMessageType, m_nsContent,
// m_nsFromUsr, m_nsToUsr, m_uiMesLocalID) to the pure mapper whose ObjC
// contract is mirrored by policy/test_msgwrap_map.py's map_msg_wrap().

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the three CMessageMgr message hooks via the plain ObjC runtime
/// (class_addMethod + method_exchangeImplementations — no substrate, no PKC
/// class is touched). Returns the number of hooks actually installed (0..3);
/// a hook is skipped when its original selector is absent from the host
/// class. Safe to call more than once (already-installed hooks are skipped).
FOUNDATION_EXPORT NSUInteger WeChatIngestInstallMessageHooks(void);

/// History export: same capture path as live messages, but ignores the
/// group/DM whitelist so every visible chat can be uploaded.
FOUNDATION_EXPORT void WeChatIngestCaptureHistoryWrap(id wrap);

NS_ASSUME_NONNULL_END
