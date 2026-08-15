#!/usr/bin/env bash
# build-dylib.sh — build WeChatIngest.dylib without Theos.
#
# Strategy:
#   1. If the iphoneos SDK exists, compile a real arm64 iOS dylib with
#      `xcrun -sdk iphoneos clang` (TrollFools-injectable into WeChat).
#   2. Otherwise fall back to a host (macOS) clang compile so the source is
#      still exercised — the output is NOT device-injectable; print a warning.
#
# Source of truth: tweak/Tweak.m (or Tweak.x) plus tweak/Settings.m and
# tweak/hooks/MessageHooks.m, tweak/hooks/SftpInboxClient.m (todo-12).
# Output: build/WeChatIngest.dylib
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TWEAK_DIR="$ROOT/tweak"
OUT_DIR="$ROOT/build"
VERSION="1.5.32"
OUT="$OUT_DIR/WeChatIngest.dylib"
VERSIONED="$OUT_DIR/WeChatIngest-${VERSION}.dylib"
mkdir -p "$OUT_DIR"

SRC=()
if [ -f "$TWEAK_DIR/Tweak.m" ]; then
  SRC+=("$TWEAK_DIR/Tweak.m")
else
  SRC+=("$TWEAK_DIR/Tweak.x")
fi
# Settings.m (todo-9) is part of the library; compile it when present.
if [ -f "$TWEAK_DIR/Settings.m" ]; then
  SRC+=("$TWEAK_DIR/Settings.m")
fi
# hooks/MessageHooks.m (todo-10) installs the CMessageMgr message hooks.
if [ -f "$TWEAK_DIR/hooks/MessageHooks.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/MessageHooks.m")
fi
# hooks/SftpInboxClient.m (todo-12) SFTP-drops events into wechat-ingest/inbox/.
if [ -f "$TWEAK_DIR/hooks/SftpInboxClient.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/SftpInboxClient.m")
fi
# hooks/OpenClawReply.m (todo-13) routes the protocol-3 OpenClaw chat request.
if [ -f "$TWEAK_DIR/hooks/OpenClawReply.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/OpenClawReply.m")
fi
# hooks/SendGate.m (todo-14) is the single canSendReply gate every send path
# consults before sendMsg:toUser:/sendLocalMsg:toUser:/pkcReplyMessage:.
if [ -f "$TWEAK_DIR/hooks/SendGate.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/SendGate.m")
fi
if [ -f "$TWEAK_DIR/hooks/Libssh2SftpChannel.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/Libssh2SftpChannel.m")
fi
if [ -f "$TWEAK_DIR/hooks/SettingsUI.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/SettingsUI.m")
fi
if [ -f "$TWEAK_DIR/hooks/Contacts.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/Contacts.m")
fi
if [ -f "$TWEAK_DIR/hooks/ContactPicker.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/ContactPicker.m")
fi
if [ -f "$TWEAK_DIR/hooks/MediaExtract.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/MediaExtract.m")
fi
if [ -f "$TWEAK_DIR/hooks/StatusSync.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/StatusSync.m")
fi
if [ -f "$TWEAK_DIR/hooks/DebugLog.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/DebugLog.m")
fi
if [ -f "$TWEAK_DIR/hooks/NetworkPath.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/NetworkPath.m")
fi
if [ -f "$TWEAK_DIR/hooks/UploadStats.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/UploadStats.m")
fi
if [ -f "$TWEAK_DIR/hooks/UploadHUD.m" ]; then
  SRC+=("$TWEAK_DIR/hooks/UploadHUD.m")
fi
# History full-export removed from the product. Do not link HistoryExport.m.

# Same flags that produced the working 1.5.4 inject. Extra "compat" switches
# (objc-runtime=ios-14, no_fixup_chains, adhoc sign) made WeChat abort on load.
CLANG="$(xcrun -f clang 2>/dev/null || echo clang)"
IOS_PREFIX="$ROOT/third_party/ios-arm64"
COMMON=(-fobjc-arc
  -fno-objc-relative-method-lists
  -fno-objc-msgsend-selector-stubs
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics
  -dynamiclib -I"$TWEAK_DIR" -I"$TWEAK_DIR/hooks")
if [ -d "$IOS_PREFIX/include" ]; then
  COMMON+=(-I"$IOS_PREFIX/include")
fi

build_one() {
  local dest="$1"
  shift
  "$CLANG" "${COMMON[@]}" \
    -isysroot "$SDK" \
    -arch arm64 \
    -miphoneos-version-min=14.0 \
    -o "$dest" \
    "$@" \
    "${LINK_LIBS[@]}"
  codesign --remove-signature "$dest" 2>/dev/null || true
}

if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  echo "Building device arm64 dylib against SDK: $SDK"
  LINK_LIBS=()
  if [ -f "$IOS_PREFIX/lib/libssh2.a" ]; then
    LINK_LIBS+=("$IOS_PREFIX/lib/libssh2.a" "$IOS_PREFIX/lib/libmbedtls.a" "$IOS_PREFIX/lib/libmbedx509.a" "$IOS_PREFIX/lib/libmbedcrypto.a" -lsqlite3)
  else
    echo "ERROR: missing $IOS_PREFIX/lib/libssh2.a — run scripts/build-ios-libssh2.sh first" >&2
    exit 1
  fi
  build_one "$OUT" "${SRC[@]}"
  cp -f "$OUT" "$VERSIONED"
  cp -f "$OUT" "$HOME/Desktop/WeChatIngest-${VERSION}.dylib"
  cp -f "$OUT" "$HOME/Downloads/WeChatIngest-${VERSION}.dylib"
  echo "OK  $VERSIONED"
  echo "OK  $HOME/Desktop/WeChatIngest-${VERSION}.dylib"
else
  MACSDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo '')"
  if [ -n "$MACSDK" ] && [ -d "$MACSDK" ]; then
    echo "WARN iphoneos SDK not found — host compile for syntax validation only"
    "$CLANG" "${COMMON[@]}" -isysroot "$MACSDK" -o "$OUT" "${SRC[@]}"
    echo "OK  $OUT (host arch — NOT device-injectable; rebuild with iphoneos SDK)"
  else
    echo "ERROR no iphoneos SDK and no macosx SDK available — cannot compile" >&2
    exit 1
  fi
fi
