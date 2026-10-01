#!/usr/bin/env bash
# The deploy-time guard: fails unless <new-serial> is strictly higher than
# the serial of the archive currently published at <base-url>. Nothing
# published yet (HTTP 404) passes; a fetch error, or a published archive
# whose signature does not verify, fails, so a network problem is never
# read as "no previous serial".
#
# usage: check-serial.sh <new-serial> <base-url> <public-key.pem>
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || ci_die "usage: check-serial.sh <new-serial> <base-url> <public-key.pem>"
new="$1"
base="$2"
pubkey="$3"
case "$new" in
  '' | *[!0-9]*) ci_die "the new serial is not a non-negative integer: $new" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
"$ci_dir/fetch-published.sh" "$base" "$work" || status=$?
case "$status" in
  0) ;;
  4)
    echo "check-serial: nothing published yet; serial $new accepted"
    exit 0
    ;;
  *) ci_die "cannot determine the published serial" ;;
esac

published="$("$ci_dir/verify.sh" "$work/catalog.tar.zst" "$work/catalog.tar.zst.sig" "$pubkey")" ||
  ci_die "the published archive does not verify; refusing to publish over it"
[ "$new" -gt "$published" ] || ci_die "serial $new is not higher than the published serial $published"
echo "check-serial: serial $new is higher than the published $published"
