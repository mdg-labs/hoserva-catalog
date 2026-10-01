#!/usr/bin/env bash
# Signs an archive with the key in $HOSERVA_CATALOG_SIGNING_KEY after
# check-key.sh has matched it against the committed public key, and writes
# the raw 64-byte Ed25519 signature to <sig>. The signature is verified
# against the committed key before it is moved into place, so a failure
# leaves no <sig> behind.
#
# usage: sign.sh <archive> <sig> <public-key.pem>
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || ci_die "usage: sign.sh <archive> <sig> <public-key.pem>"
archive="$1"
sig="$2"
pubkey="$3"
[ -f "$archive" ] || ci_die "no such archive: $archive"

"$ci_dir/check-key.sh" "$pubkey" >/dev/null || ci_die "the signing key does not match $pubkey"

rm -f -- "$sig"
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s' "$HOSERVA_CATALOG_SIGNING_KEY" >"$work/key.pem"
openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$archive" -out "$work/sig" 2>/dev/null ||
  ci_die "signing failed"
[ "$(wc -c <"$work/sig")" -eq 64 ] || ci_die "the signature is not 64 bytes"
ci_verify "$archive" "$work/sig" "$pubkey" || ci_die "the new signature does not verify against $pubkey"

cp -- "$work/sig" "$sig.partial"
mv -- "$sig.partial" "$sig"
chmod 0644 "$sig"
echo "signed $archive"
