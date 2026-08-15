#!/usr/bin/env bash
# check-no-dm-send.sh — todo-14 gate: every reply-send call goes through the
# single canSendReply gate.
#
# Fails (exit 1) if any of:
#   - policy/test_no_dm_reply.py or policy/send_gate.py missing
#   - the Python twin does not define canSendReply(chatKind, isSelf, policy)
#   - tweak/hooks/SendGate.{h,m} missing
#   - the ObjC gate WeChatIngestCanSendReply is not defined in SendGate.m
#   - SendGate.m does not guard every send wrapper with the gate (fewer than
#     three `if (!WeChatIngestCanSendReply` guards)
#   - any of the three send selectors (sendMsg:toUser: / sendLocalMsg:toUser: /
#     pkcReplyMessage:) appears in a tweak source OUTSIDE SendGate.m — a send
#     call outside the gate (comment lines are stripped first, so doc comments
#     like SftpInboxClient's "never calls sendMsg:toUser:" don't false-positive)
#   - any send selector is not represented inside SendGate.m — a send path
#     without a gated wrapper
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TWEAK_DIR="$ROOT/tweak"
HOOKS_DIR="$TWEAK_DIR/hooks"
POLICY_DIR="$ROOT/policy"
GATE_FILE="$HOOKS_DIR/SendGate.m"
fail=0

die() { echo "FAIL: $*" >&2; fail=1; }

SEND_SELECTORS=("sendMsg:toUser:" "sendLocalMsg:toUser:" "pkcReplyMessage:")

# --- Python twin + contract test ---------------------------------------------
[ -f "$POLICY_DIR/test_no_dm_reply.py" ] || die "missing policy/test_no_dm_reply.py"
[ -f "$POLICY_DIR/send_gate.py" ] || die "missing policy/send_gate.py"
if grep -q 'def canSendReply' "$POLICY_DIR/send_gate.py"; then
  echo "OK  python twin defines canSendReply(chatKind, isSelf, policy)"
else
  die "policy/send_gate.py must define canSendReply(chatKind, isSelf, policy)"
fi

# --- ObjC gate files ----------------------------------------------------------
[ -f "$HOOKS_DIR/SendGate.h" ] || die "missing tweak/hooks/SendGate.h"
[ -f "$GATE_FILE" ] || die "missing tweak/hooks/SendGate.m"

if grep -q '^BOOL WeChatIngestCanSendReply' "$GATE_FILE"; then
  echo "OK  WeChatIngestCanSendReply defined in SendGate.m"
else
  die "SendGate.m does not define BOOL WeChatIngestCanSendReply(...)"
fi

# --- every send wrapper must consult the gate ---------------------------------
guard_count="$(grep -c 'if (!WeChatIngestCanSendReply' "$GATE_FILE" || true)"
if [ "$guard_count" -ge 3 ]; then
  echo "OK  SendGate.m guards $guard_count send wrappers with the gate"
else
  die "SendGate.m must guard each send wrapper with the gate (found $guard_count/3)"
fi

# --- no send selector outside the gate ----------------------------------------
# Scan every .m/.h under tweak/ except SendGate.{h,m}; strip // comments so
# doc comments that merely name a selector do not count as a send call.
for sel in "${SEND_SELECTORS[@]}"; do
  hits=0
  while IFS= read -r src; do
    case "$src" in
      "$HOOKS_DIR/SendGate.h" | "$HOOKS_DIR/SendGate.m") continue ;;
    esac
    if sed 's|//.*||' "$src" | grep -Fq -- "$sel"; then
      echo "FAIL: send selector '$sel' appears outside the gate in $src"
      hits=$((hits + 1))
    fi
  done < <(find "$TWEAK_DIR" \( -name '*.m' -o -name '*.h' \) -type f | sort)
  if [ "$hits" -eq 0 ]; then
    echo "OK  no '$sel' call outside SendGate.m"
  else
    fail=1
  fi
done

# --- every send selector is represented inside the gated wrapper file ---------
for sel in "${SEND_SELECTORS[@]}"; do
  if grep -Fq -- "$sel" "$GATE_FILE"; then
    echo "OK  '$sel' has a gated wrapper in SendGate.m"
  else
    die "send selector '$sel' has no gated wrapper in SendGate.m"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: every send path goes through canSendReply; DM/self replies are hard-disabled"
  exit 0
fi
exit 1
