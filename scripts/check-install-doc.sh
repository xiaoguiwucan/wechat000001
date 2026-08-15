#!/usr/bin/env bash
# check-install-doc.sh — todo-16 acceptance gates for docs/install-trollfools.md.
#
# Fails (exit 1) unless the install doc:
#   1. exists
#   2. contains "TrollFools"
#   3. contains "com.tencent.xin"
#   4. contains "18790"
#   5. does NOT contain an inline password assignment
set -eu

DOC="docs/install-trollfools.md"
fail=0

if [ ! -f "$DOC" ]; then
  echo "FAIL  missing $DOC"
  exit 1
fi

for needle in TrollFools com.tencent.xin 18790; do
  if grep -qF "$needle" "$DOC"; then
    echo "OK    contains '$needle'"
  else
    echo "FAIL  missing '$needle' in $DOC"
    fail=1
  fi
done

if grep -qiE 'password[[:space:]]*[:=][[:space:]]*[^([:space:]|]+' "$DOC"; then
  echo "FAIL  inline password must NOT appear in $DOC"
  fail=1
else
  echo "OK    no inline password in $DOC"
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: install doc gates not satisfied"
  exit 1
fi
echo "PASS: install doc gates satisfied"
