#!/usr/bin/env bash
# check-settings-keys.sh — TODO-9 gate: the tweak settings source must persist
# to the NSUserDefaults suite `com.zkx.wechat.ingest` under OUR key names and
# must never write PKC's keys (pkcOpenClawEnable) so both tweaks can coexist.
#
# Fails (exit 1) if:
#   - tweak/Settings.h or tweak/Settings.m is missing
#   - any required key/literal (suite, keys, gateway default 18790, the Test
#     button hook testConnection) is absent from the tweak sources
#   - `pkcOpenClawEnable` appears anywhere in the tweak sources — a write
#     target that would fight PKC if both tweaks stay installed
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TWEAK_DIR="$ROOT/tweak"
fail=0

die() { echo "FAIL: $*" >&2; fail=1; }

# --- required settings source files -----------------------------------------
for f in Settings.h Settings.m; do
  [ -f "$TWEAK_DIR/$f" ] || die "missing tweak/$f"
done

FILES=( "$TWEAK_DIR/Settings.h" "$TWEAK_DIR/Settings.m" )
if [ -f "$TWEAK_DIR/Tweak.m" ]; then
  FILES+=( "$TWEAK_DIR/Tweak.m" )
elif [ -f "$TWEAK_DIR/Tweak.x" ]; then
  FILES+=( "$TWEAK_DIR/Tweak.x" )
fi
SOURCE_TEXT="$(cat "${FILES[@]}")"

# --- required keys / literals ------------------------------------------------
# Suite, every required settings key, the gateway port default (18790) and the
# Test button hook (testConnection — the testOpenClaw shape).
REQUIRED_LITERALS=(
  'com.zkx.wechat.ingest'
  'ingest.enable'
  'ingest.ssh.host'
  'ingest.ssh.port'
  'ingest.ssh.user'
  'ingest.ssh.password'
  'ingest.gateway.port'
  '18790'
  'ingest.token'
  'ingest.command.prefix'
  'ingest.groups'
  'ingest.dms'
  'testConnection'
)

for literal in "${REQUIRED_LITERALS[@]}"; do
  if printf '%s' "$SOURCE_TEXT" | grep -Fq -- "$literal"; then
    echo "OK  required literal present: $literal"
  else
    die "required settings literal missing from tweak sources: $literal"
  fi
done

# --- PKC keys forbidden ------------------------------------------------------
# Writing pkcOpenClawEnable would fight PKC if both tweaks stay installed.
# Any occurrence in the sources counts as a write target.
if printf '%s' "$SOURCE_TEXT" | grep -n 'pkcOpenClawEnable' >/dev/null 2>&1; then
  die "source mentions pkcOpenClawEnable as a write target — must use the com.zkx.wechat.ingest suite keys only"
else
  echo "OK  no pkcOpenClawEnable write target in tweak sources"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: settings keys present, pkcOpenClawEnable not written, Test hook wired"
  exit 0
fi
exit 1
