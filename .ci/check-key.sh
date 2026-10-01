#!/usr/bin/env bash
# Checks that the public half of the private key in $HOSERVA_CATALOG_SIGNING_KEY
# equals the committed public key. Prints only "match" or "mismatch" on
# stdout; never key material. Exits non-zero unless it matches.
#
# usage: check-key.sh <public-key.pem>
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || ci_die "usage: check-key.sh <public-key.pem>"
pubkey="$1"

[ -n "${HOSERVA_CATALOG_SIGNING_KEY:-}" ] || ci_die "HOSERVA_CATALOG_SIGNING_KEY is not set"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s' "$HOSERVA_CATALOG_SIGNING_KEY" >"$work/key.pem"
openssl pkey -in "$work/key.pem" -pubout -outform DER -out "$work/derived.der" 2>/dev/null ||
  ci_die "HOSERVA_CATALOG_SIGNING_KEY is not a readable private key"
openssl pkey -pubin -in "$pubkey" -outform DER -out "$work/committed.der" 2>/dev/null ||
  ci_die "$pubkey is not a readable public key"

if cmp -s "$work/derived.der" "$work/committed.der"; then
  echo "match"
else
  echo "mismatch"
  exit 1
fi
