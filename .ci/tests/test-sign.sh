#!/usr/bin/env bash
# check-key.sh, sign.sh and verify.sh with throwaway keypairs.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

gen_key good
gen_key other
expect_ok "$ci_root/build.sh" "$fixtures/catalog" "$T/dist"
archive="$T/dist/catalog.tar.zst"
sig="$T/dist/catalog.tar.zst.sig"

# check-key: match, mismatch, unreadable, unset.
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/good.key")" "$ci_root/check-key.sh" "$T/good.pub" >"$T/out"
assert_eq "$(cat "$T/out")" match "check-key output on a match"

status=0
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/other.key")" "$ci_root/check-key.sh" "$T/good.pub" >"$T/out" 2>"$T/err" || status=$?
assert_eq "$status" 1 "check-key status on a mismatch"
assert_eq "$(cat "$T/out")" mismatch "check-key output on a mismatch"
if grep -q 'PRIVATE KEY\|BEGIN' "$T/out" "$T/err"; then t_fail "check-key printed key material"; fi

status=0
HOSERVA_CATALOG_SIGNING_KEY="not a key" "$ci_root/check-key.sh" "$T/good.pub" >"$T/out" 2>"$T/err" || status=$?
[ "$status" -ne 0 ] || t_fail "check-key accepted an unreadable key"
assert_eq "$(cat "$T/out")" "" "check-key stdout on an unreadable key"
grep -q 'not a readable private key' "$T/err" || t_fail "check-key did not say the key is unreadable"

status=0
HOSERVA_CATALOG_SIGNING_KEY="" "$ci_root/check-key.sh" "$T/good.pub" >"$T/out" 2>&1 || status=$?
[ "$status" -ne 0 ] || t_fail "check-key accepted an unset key"

# sign: a 64-byte raw signature that verifies, with the script and with openssl.
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/good.key")" expect_ok "$ci_root/sign.sh" "$archive" "$sig" "$T/good.pub"
assert_eq "$(wc -c <"$sig")" 64 "signature size"
expect_ok "$ci_root/verify.sh" "$archive" "$sig" "$T/good.pub"
expect_ok openssl pkeyutl -verify -pubin -inkey "$T/good.pub" -rawin -in "$archive" -sigfile "$sig"
assert_eq "$("$ci_root/verify.sh" "$archive" "$sig" "$T/good.pub")" "$(zstd -dc -- "$archive" | tar -xO index.json | jq -r .serial)" "verify prints the serial"

# The signature fails against another key and after the archive is altered.
expect_fail "$ci_root/verify.sh" "$archive" "$sig" "$T/other.pub"
cp "$archive" "$T/altered.tar.zst"
printf 'x' >>"$T/altered.tar.zst"
expect_fail "$ci_root/verify.sh" "$T/altered.tar.zst" "$sig" "$T/good.pub"
expect_fail openssl pkeyutl -verify -pubin -inkey "$T/good.pub" -rawin -in "$T/altered.tar.zst" -sigfile "$sig"

# A mismatching or unreadable key signs nothing.
printf 'stale' >"$T/stale.sig"
status=0
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/other.key")" "$ci_root/sign.sh" "$archive" "$T/stale.sig" "$T/good.pub" >"$T/out" 2>&1 || status=$?
[ "$status" -ne 0 ] || t_fail "sign accepted a key that does not match"
[ "$(cat "$T/stale.sig")" = stale ] || t_fail "sign touched the existing signature before the key check passed"
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/other.key")" expect_fail "$ci_root/sign.sh" "$archive" "$T/never.sig" "$T/good.pub"
[ ! -e "$T/never.sig" ] || t_fail "a mismatching key produced a signature"
HOSERVA_CATALOG_SIGNING_KEY="garbage" expect_fail "$ci_root/sign.sh" "$archive" "$T/never.sig" "$T/good.pub"
[ ! -e "$T/never.sig" ] || t_fail "an unreadable key produced a signature"

# The signing key never lands in the output directory.
if grep -rq 'PRIVATE KEY' "$T/dist"; then t_fail "key material in the output directory"; fi

echo "test-sign: ok"
