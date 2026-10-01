#!/usr/bin/env bash
# Downloads catalog.tar.zst and catalog.tar.zst.sig from <base-url> into
# <dest-dir>. Exit status: 0 both downloaded; 4 the archive is not
# published (HTTP 404); 1 anything else, a network error included.
#
# usage: fetch-published.sh <base-url> <dest-dir>
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 2 ] || ci_die "usage: fetch-published.sh <base-url> <dest-dir>"
base="${1%/}"
dest="$2"
mkdir -p "$dest"

# fetch <name> prints the HTTP status; a transport failure is an error, not a status.
fetch() {
  curl --silent --show-error --max-time 60 --retry 3 --retry-delay 2 \
    --header 'Cache-Control: no-cache' --output "$dest/$1" --write-out '%{http_code}' "$base/$1"
}

code="$(fetch catalog.tar.zst)" || ci_die "cannot fetch $base/catalog.tar.zst"
case "$code" in
  200) ;;
  404)
    rm -f -- "$dest/catalog.tar.zst"
    echo "fetch-published: nothing is published at $base yet" >&2
    exit 4
    ;;
  *) ci_die "$base/catalog.tar.zst answered HTTP $code" ;;
esac

code="$(fetch catalog.tar.zst.sig)" || ci_die "cannot fetch $base/catalog.tar.zst.sig"
[ "$code" = 200 ] || ci_die "$base/catalog.tar.zst.sig answered HTTP $code"
