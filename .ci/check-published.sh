#!/usr/bin/env bash
# The fetch-back after a deploy: fetches the published archive and its
# signature from <base-url>, verifies the signature against the committed
# public key and checks that the archive's serial equals <expected-serial>.
# Retried while the site still serves nothing or an older archive.
#
# usage: check-published.sh <base-url> <expected-serial> <public-key.pem>
#
# CATALOG_FETCH_ATTEMPTS (default 10) and CATALOG_FETCH_SLEEP (default 15,
# seconds) bound the retries.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || ci_die "usage: check-published.sh <base-url> <expected-serial> <public-key.pem>"
base="$1"
expected="$2"
pubkey="$3"
attempts="${CATALOG_FETCH_ATTEMPTS:-10}"
pause="${CATALOG_FETCH_SLEEP:-15}"
case "$expected" in
  '' | *[!0-9]*) ci_die "the expected serial is not a non-negative integer: $expected" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

last="nothing fetched"
for ((try = 1; try <= attempts; try++)); do
  status=0
  "$ci_dir/fetch-published.sh" "$base" "$work" || status=$?
  if [ "$status" -eq 0 ]; then
    if published="$("$ci_dir/verify.sh" "$work/catalog.tar.zst" "$work/catalog.tar.zst.sig" "$pubkey")"; then
      if [ "$published" = "$expected" ]; then
        echo "check-published: $base serves serial $published, signature verified"
        exit 0
      fi
      last="$base serves serial $published, expected $expected"
    else
      last="the archive at $base does not verify against $pubkey"
    fi
  else
    last="fetch from $base failed (status $status)"
  fi
  if [ "$try" -lt "$attempts" ]; then
    sleep "$pause"
  fi
done
ci_die "after $attempts attempts: $last"
