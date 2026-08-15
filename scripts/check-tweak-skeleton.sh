#!/usr/bin/env bash
# check-tweak-skeleton.sh — TODO-8 gate: the Theos tweak skeleton must target
# WeChat (com.tencent.xin), use only ObjC runtime swizzling (objc/runtime.h
# method_exchangeImplementations), and must NOT link/import substrate.h.
#
# Fails (exit 1) if:
#   - tweak/Makefile, tweak/Tweak.{m,x}, tweak/control or tweak/WeChatIngest.plist missing
#   - the Filter plist does not name bundle id com.tencent.xin
#   - the Filter plist targets com.apple.springboard
#   - any tweak source imports substrate.h, or the Makefile links Substrate
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TWEAK_DIR="$ROOT/tweak"
fail=0

die() { echo "FAIL: $*" >&2; fail=1; }

# --- required files ---------------------------------------------------------
for f in Makefile control WeChatIngest.plist; do
  [ -f "$TWEAK_DIR/$f" ] || die "missing tweak/$f"
done
SRC=""
if [ -f "$TWEAK_DIR/Tweak.m" ]; then
  SRC="$TWEAK_DIR/Tweak.m"
elif [ -f "$TWEAK_DIR/Tweak.x" ]; then
  SRC="$TWEAK_DIR/Tweak.x"
else
  die "missing tweak/Tweak.m (or Tweak.x)"
fi

# --- filter bundle id must be com.tencent.xin ------------------------------
PLIST="$TWEAK_DIR/WeChatIngest.plist"
# Read the Filter:Bundles array by index via PlistBuddy when available,
# else fall back to scanning the plist XML for <string> entries.
if /usr/libexec/PlistBuddy -c "Print :Filter:Bundles" "$PLIST" >/dev/null 2>&1; then
  BUNDLES=""
  i=0
  while /usr/libexec/PlistBuddy -c "Print :Filter:Bundles:$i" "$PLIST" >/dev/null 2>&1; do
    BUNDLES="$BUNDLES
$(/usr/libexec/PlistBuddy -c "Print :Filter:Bundles:$i" "$PLIST" 2>/dev/null)"
    i=$((i + 1))
  done
else
  BUNDLES="$(grep -o '<string>[^<]*</string>' "$PLIST" | sed -e 's/<[^>]*>//g')"
fi

if printf '%s\n' "$BUNDLES" | grep -qx 'com.tencent.xin'; then
  echo "OK  Filter bundle id com.tencent.xin"
else
  die "Filter plist must target bundle id com.tencent.xin (got: $(printf '%s' "$BUNDLES" | tr '\n' ' '))"
fi

if printf '%s\n' "$BUNDLES" | grep -qx 'com.apple.springboard'; then
  die "Filter plist targets com.apple.springboard — must be com.tencent.xin"
fi

# --- substrate forbidden: check import/include lines, not comments ----------
if [ -n "$SRC" ]; then
  if grep -nE '^[[:space:]]*#(import|include)[[:space:]]*[<"]substrate' "$SRC" >/dev/null 2>&1; then
    die "$(basename "$SRC") imports substrate.h — substrate is forbidden"
  fi
  if grep -n 'method_exchangeImplementations' "$SRC" >/dev/null 2>&1; then
    echo "OK  uses objc/runtime.h method_exchangeImplementations"
  else
    die "$(basename "$SRC") does not use method_exchangeImplementations"
  fi
fi

if grep -nE '^[[:space:]]*#(import|include)[[:space:]]*<objc/runtime.h>' "$SRC" >/dev/null 2>&1; then
  echo "OK  imports objc/runtime.h"
else
  die "$SRC does not import <objc/runtime.h>"
fi

if grep -nE '\-lsubstrate|_LIBRARIES[[:space:]]*\+?=[[:space:]]*[^#]*substrate' "$TWEAK_DIR/Makefile" >/dev/null 2>&1; then
  die "Makefile links Substrate — forbidden"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: tweak skeleton targets com.tencent.xin, substrate-free"
  exit 0
fi
exit 1
