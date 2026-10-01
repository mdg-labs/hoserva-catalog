#!/usr/bin/env bash
# check-serial.sh (the deploy-time guard), check-published.sh (the
# fetch-back) and fetch-published.sh against a local HTTP server.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

gen_key good
gen_key other
expect_ok "$ci_root/build.sh" "$fixtures/catalog" "$T/published"
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/good.key")" expect_ok "$ci_root/sign.sh" \
  "$T/published/catalog.tar.zst" "$T/published/catalog.tar.zst.sig" "$T/good.pub"
serial="$(zstd -dc -- "$T/published/catalog.tar.zst" | tar -xO index.json | jq -r .serial)"

export CATALOG_FETCH_ATTEMPTS=2 CATALOG_FETCH_SLEEP=0

serve_dir "$T/published"

# The guard: only a strictly higher serial passes.
expect_ok "$ci_root/check-serial.sh" "$((serial + 1))" "$base_url" "$T/good.pub"
expect_fail "$ci_root/check-serial.sh" "$serial" "$base_url" "$T/good.pub"
grep -q 'not higher' "$T/out" || t_fail "the guard did not say why it refused an equal serial"
expect_fail "$ci_root/check-serial.sh" "$((serial - 1))" "$base_url" "$T/good.pub"
expect_fail "$ci_root/check-serial.sh" "abc" "$base_url" "$T/good.pub"
expect_fail "$ci_root/check-serial.sh" "" "$base_url" "$T/good.pub"

# A published archive that does not verify against the committed key blocks publishing.
expect_fail "$ci_root/check-serial.sh" "$((serial + 1))" "$base_url" "$T/other.pub"

# Fetch-back: the expected serial and a verifying signature pass; anything else fails.
expect_ok "$ci_root/check-published.sh" "$base_url" "$serial" "$T/good.pub"
expect_fail "$ci_root/check-published.sh" "$base_url" "$((serial + 1))" "$T/good.pub"
expect_fail "$ci_root/check-published.sh" "$base_url" "$serial" "$T/other.pub"

# A published signature over different bytes is refused.
mkdir "$T/tampered"
cp "$T/published/catalog.tar.zst" "$T/tampered/catalog.tar.zst"
cp "$T/published/catalog.tar.zst.sig" "$T/tampered/catalog.tar.zst.sig"
printf 'x' >>"$T/tampered/catalog.tar.zst"
stop_server
serve_dir "$T/tampered"
expect_fail "$ci_root/check-serial.sh" "$((serial + 1))" "$base_url" "$T/good.pub"
expect_fail "$ci_root/check-published.sh" "$base_url" "$serial" "$T/good.pub"
stop_server

# Nothing published (404) passes the guard and fails the fetch-back; the
# fetch helper tells 404 apart from an error.
mkdir "$T/nothing"
serve_dir "$T/nothing"
expect_ok "$ci_root/check-serial.sh" 1 "$base_url" "$T/good.pub"
grep -q 'nothing published yet' "$T/out" || t_fail "the guard did not report an empty site"
expect_fail "$ci_root/check-published.sh" "$base_url" 1 "$T/good.pub"
status=0
"$ci_root/fetch-published.sh" "$base_url" "$T/fetched" >"$T/out" 2>&1 || status=$?
assert_eq "$status" 4 "fetch-published status on a 404"

# An archive without its signature is an error, not "nothing published".
mkdir "$T/unsigned"
cp "$T/published/catalog.tar.zst" "$T/unsigned/"
stop_server
serve_dir "$T/unsigned"
status=0
"$ci_root/fetch-published.sh" "$base_url" "$T/fetched" >"$T/out" 2>&1 || status=$?
assert_eq "$status" 1 "fetch-published status on a missing signature"
expect_fail "$ci_root/check-serial.sh" 99999999999 "$base_url" "$T/good.pub"
stop_server

# A network error is never read as "nothing published yet".
status=0
"$ci_root/fetch-published.sh" "$base_url" "$T/fetched" >"$T/out" 2>&1 || status=$?
assert_eq "$status" 1 "fetch-published status on a refused connection"
expect_fail "$ci_root/check-serial.sh" 99999999999 "$base_url" "$T/good.pub"
expect_fail "$ci_root/check-published.sh" "$base_url" "$serial" "$T/good.pub"

echo "test-serial: ok"
