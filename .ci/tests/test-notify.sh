#!/usr/bin/env bash
# notify-published.sh (the hoserva.dev rebuild request after a publish) with gh
# stubbed on PATH: one catalog-published dispatch carrying the serial, and a
# missing token or a failed call is a warning, never a failure.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PATH="$ci_root/tests/stubs:$PATH"
export PATH
export STUB_LOG="$T/stub.log"
repo=mdg-labs/hoserva
serial=1791338858
token="test-token-0123456789abcdef"

reset() {
  : >"$STUB_LOG"
  rm -f "$STUB_LOG.token"
  unset STUB_DISPATCH_FAIL STUB_DISPATCH_HANG STUB_LOOKUP_FAIL CATALOG_NOTIFY_TIMEOUT GH_TOKEN
}

# A publish sends exactly one dispatch: the right repository, event type and
# serial, authenticated by the token from the environment.
reset
GH_TOKEN="$token" expect_ok "$ci_root/notify-published.sh" "$repo" "$serial"
assert_eq "$(grep -c '^DISPATCH ' "$STUB_LOG")" 1 "dispatch calls"
assert_eq "$(grep -c '^gh ' "$STUB_LOG")" 1 "gh calls"
assert_eq "$(grep '^DISPATCH ' "$STUB_LOG")" \
  "DISPATCH repos/$repo/dispatches {\"event_type\":\"catalog-published\",\"client_payload\":{\"serial\":\"$serial\"}}" "dispatch request"
assert_eq "$(cat "$STUB_LOG.token")" "$token" "the token the dispatch ran with"
grep -q "asked $repo to rebuild hoserva.dev for serial $serial" "$T/out" || t_fail "the success was not reported"

# The token never reaches a command line, the log or the output.
if grep -qF "$token" "$STUB_LOG" "$T/out"; then
  t_fail "the token was printed or put on a command line"
fi

# A missing or empty token is a warning: nothing is sent and the step succeeds.
reset
expect_ok "$ci_root/notify-published.sh" "$repo" "$serial"
grep -q '^::warning' "$T/out" || t_fail "an unset token gave no warning"
assert_eq "$(grep -c '^gh ' "$STUB_LOG" || true)" 0 "gh calls without a token"
reset
GH_TOKEN="" expect_ok "$ci_root/notify-published.sh" "$repo" "$serial"
grep -q '^::warning' "$T/out" || t_fail "an empty token gave no warning"
assert_eq "$(grep -c '^gh ' "$STUB_LOG" || true)" 0 "gh calls with an empty token"

# A failed dispatch (a rejected token, a server error) is a warning that names
# the reason and never the token.
reset
export STUB_DISPATCH_FAIL=1
GH_TOKEN="$token" expect_ok "$ci_root/notify-published.sh" "$repo" "$serial"
grep -q '^::warning.*dispatch to '"$repo"' failed.*HTTP 403' "$T/out" || t_fail "a failed dispatch gave no warning naming the reason"
assert_eq "$(grep -c '^::warning' "$T/out")" 1 "warnings for a failed dispatch"
if grep -qF "$token" "$T/out"; then
  t_fail "the token was printed after a failed dispatch"
fi

reset
export STUB_LOOKUP_FAIL=1
GH_TOKEN="$token" expect_ok "$ci_root/notify-published.sh" "$repo" "$serial"
grep -q '^::warning' "$T/out" || t_fail "a server error gave no warning"

# A call that hangs is cut off at the timeout and is a warning too.
reset
export STUB_DISPATCH_HANG=1 CATALOG_NOTIFY_TIMEOUT=1
GH_TOKEN="$token" expect_ok "$ci_root/notify-published.sh" "$repo" "$serial"
grep -q '^::warning' "$T/out" || t_fail "a hanging dispatch gave no warning"

# A wrong call of the script itself is still a failure, and sends nothing.
reset
GH_TOKEN="$token" expect_fail "$ci_root/notify-published.sh" "$repo"
GH_TOKEN="$token" expect_fail "$ci_root/notify-published.sh" "$repo" ""
GH_TOKEN="$token" expect_fail "$ci_root/notify-published.sh" "$repo" "12ab"
assert_eq "$(grep -c '^gh ' "$STUB_LOG" || true)" 0 "gh calls for a bad call of the script"

echo "test-notify: ok"
