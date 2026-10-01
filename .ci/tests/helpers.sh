#!/usr/bin/env bash
# Shared by the tooling tests. Sourced, never run. Keys are generated per
# test in a temp directory that is deleted on exit; no real key is used and
# none is committed.
set -euo pipefail

ci_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034 # read by the tests that source this file
fixtures="$ci_root/fixtures"
T="$(mktemp -d)"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT

t_fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || t_fail "${3:-values differ}: got [$1], want [$2]"
}

expect_ok() {
  "$@" >"$T/out" 2>&1 || {
    cat "$T/out" >&2
    t_fail "expected success: $*"
  }
}

expect_fail() {
  if "$@" >"$T/out" 2>&1; then
    cat "$T/out" >&2
    t_fail "expected failure: $*"
  fi
}

gen_key() {
  openssl genpkey -algorithm ed25519 -out "$T/$1.key" 2>/dev/null
  openssl pkey -in "$T/$1.key" -pubout -out "$T/$1.pub" 2>/dev/null
}

# serve_dir <dir> starts a local HTTP server and sets $base_url.
serve_dir() {
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$1" >"$T/server.log" 2>&1 &
  server_pid=$!
  local port=""
  for _ in $(seq 1 50); do
    port="$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$T/server.log" | head -n 1)"
    [ -z "$port" ] || break
    sleep 0.1
  done
  [ -n "$port" ] || t_fail "the test HTTP server did not start"
  # shellcheck disable=SC2034 # read by the tests that source this file
  base_url="http://127.0.0.1:$port"
}

stop_server() {
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
}
