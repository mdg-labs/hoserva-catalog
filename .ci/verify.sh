#!/usr/bin/env bash
# Verifies a detached raw Ed25519 signature over an archive and prints the
# archive's serial. Exits non-zero when the signature does not verify.
#
# usage: verify.sh <archive> <sig> <public-key.pem>
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || ci_die "usage: verify.sh <archive> <sig> <public-key.pem>"
ci_verify "$1" "$2" "$3" || ci_die "the signature of $1 does not verify against $3"
ci_archive_serial "$1"
