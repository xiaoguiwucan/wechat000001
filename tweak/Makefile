# WeChatIngest — substrate-free Theos build for TrollFools injection.
#
# Built as a plain library (library.mk) instead of a tweak (tweak.mk) so that
# NOTHING links CydiaSubstrate: every hook is a plain ObjC runtime swap via
# objc/runtime.h method_exchangeImplementations (see Tweak.m). No Logos
# preprocessor is used, so Tweak.m is compiled as-is by clang.
#
# Usage (on a Mac with Theos installed):
#   export THEOS=/path/to/theos
#   make          # -> libWeChatIngest.dylib in the staging dir
#   make package  # -> .deb (NOT used; TrollStore/TrollFools injects the dylib)
#
# TrollFools injects the produced arm64 dylib into com.tencent.xin directly.
# If Theos is missing, use scripts/build-dylib.sh (xcrun clang) instead.

export ARCHS = arm64
export TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WeChatIngest
WeChatIngest_FILES = Tweak.m Settings.m hooks/MessageHooks.m hooks/SftpInboxClient.m hooks/OpenClawReply.m hooks/SendGate.m hooks/Libssh2SftpChannel.m hooks/SettingsUI.m hooks/MediaExtract.m hooks/StatusSync.m hooks/Contacts.m hooks/ContactPicker.m hooks/DebugLog.m hooks/NetworkPath.m hooks/UploadStats.m hooks/UploadHUD.m
WeChatIngest_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics
WeChatIngest_CFLAGS = -fobjc-arc
WeChatIngest_INSTALL_PATH = /usr/lib

include $(THEOS)/makefiles/library.mk

# Theos prefixes library output with "lib"; TrollFools accepts either name,
# but copy to the canonical deliverable name too.
after-stage::
	@cp "$(THEOS_STAGING_DIR)/usr/lib/libWeChatIngest.dylib" WeChatIngest.dylib 2>/dev/null || true
