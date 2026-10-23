#!/bin/sh
# Verifies the bundle is signed with the hardened runtime and allow-jit, and that Chez can
# generate and run machine code under it (plan §10: hardened runtime vs Chez codegen).
set -eu
app="$1"

codesign --verify --strict --verbose=1 "$app"
codesign -d --verbose=2 "$app" 2>&1 | grep -q 'flags=.*runtime' ||
    { echo "hardened runtime flag missing" >&2; exit 1; }
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'com.apple.security.cs.allow-jit' ||
    { echo "allow-jit entitlement missing" >&2; exit 1; }

out=$("$app/Contents/MacOS/profane" --self-test)
echo "$out"
case "$out" in ok:*) ;; *) echo "self-test failed" >&2; exit 1 ;; esac
