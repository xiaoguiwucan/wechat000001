#!/usr/bin/env bash
# check-hooks.sh — todo-10 gate: the three PKC-proven CMessageMgr message
# hooks must be swizzled with the plain ObjC runtime.
#
# Fails (exit 1) if any of:
#   - tweak/hooks/MessageHooks.{h,m} missing
#   - any of the three PKC-proven selectors
#     (AddMsg:MsgWrap: / AsyncOnPreAddMsg:MsgWrap: / HandleAppMsg:MsgWrap:)
#     is not referenced in tweak/hooks/MessageHooks.m
#   - tweak/hooks/MessageHooks.m does not use method_exchangeImplementations
#   - any hook does not forward to the original IMP first (each prefixed
#     selector must appear at least twice: as the swap target and as the
#     forward call inside the hook IMP)
#   - tweak/Tweak.m does not wire the hooks (no WeChatIngestInstallMessageHooks call)
#   - MessageHooks.m hooks a PKC class (any pkc-prefixed swizzle target)
#   - MessageHooks.m imports substrate.h
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$ROOT/tweak/hooks"
fail=0

die() { echo "FAIL: $*" >&2; fail=1; }

# --- required files ---------------------------------------------------------
[ -f "$HOOKS_DIR/MessageHooks.m" ] || die "missing tweak/hooks/MessageHooks.m"
[ -f "$HOOKS_DIR/MessageHooks.h" ] || die "missing tweak/hooks/MessageHooks.h"

# --- all three selectors must be referenced in the hooks source -------------
for sel in "AddMsg:MsgWrap:" "AsyncOnPreAddMsg:MsgWrap:" "HandleAppMsg:MsgWrap:"; do
  if grep -Fq "$sel" "$HOOKS_DIR/MessageHooks.m"; then
    echo "OK  selector $sel referenced"
  else
    die "selector '$sel' not referenced in tweak/hooks/MessageHooks.m"
  fi
done

# --- method_exchangeImplementations must be used ----------------------------
if grep -q 'method_exchangeImplementations' "$HOOKS_DIR/MessageHooks.m"; then
  echo "OK  uses method_exchangeImplementations"
else
  die "tweak/hooks/MessageHooks.m does not use method_exchangeImplementations"
fi

# --- forward-original-first: each prefixed selector appears as both the swap
#     target and the forward call inside its hook IMP -------------------------
for fwd in "ing_AddMsg:MsgWrap:" "ing_AsyncOnPreAddMsg:MsgWrap:" "ing_HandleAppMsg:MsgWrap:"; do
  count="$(grep -cF "$fwd" "$HOOKS_DIR/MessageHooks.m" || true)"
  if [ "$count" -ge 2 ]; then
    echo "OK  $fwd forwards to original IMP ($count references)"
  else
    die "hook '$fwd' must be referenced at least twice (swap target + forward call), found $count"
  fi
done

# --- constructor wiring ------------------------------------------------------
if grep -q 'WeChatIngestInstallMessageHooks' "$ROOT/tweak/Tweak.m"; then
  echo "OK  Tweak.m wires WeChatIngestInstallMessageHooks"
else
  die "tweak/Tweak.m does not call WeChatIngestInstallMessageHooks"
fi

# --- must NOT hook PKC classes ----------------------------------------------
if grep -nE '@selector\(pkc|"(pkc[^"]*:?)"' "$HOOKS_DIR/MessageHooks.m" >/dev/null 2>&1; then
  die "MessageHooks.m must not hook PKC classes (pkc selector found)"
fi

# --- substrate forbidden -----------------------------------------------------
if grep -nE '^[[:space:]]*#(import|include)[[:space:]]*[<"]substrate' "$HOOKS_DIR/MessageHooks.m" >/dev/null 2>&1; then
  die "MessageHooks.m imports substrate.h — forbidden"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: three PKC-proven message hooks swizzled via method_exchangeImplementations"
  exit 0
fi
exit 1
