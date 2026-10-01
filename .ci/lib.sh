#!/usr/bin/env bash
# Shared helpers for the catalog CI scripts. Sourced, never run.

# shellcheck disable=SC2034 # read by the scripts that source this file
ci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ci_die() {
  echo "$(basename "$0"): $*" >&2
  exit 1
}

# ci_entries <catalog-dir> prints, NUL-separated and sorted, the top-level
# entries `hoserva template lint` treats as template directories: every
# non-dot directory, and every non-dot symlink that is not a plain file.
ci_entries() {
  local dir="$1" entry
  for entry in "$dir"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -d "$entry" ] || { [ -L "$entry" ] && [ ! -f "$entry" ]; }; then
      printf '%s\0' "$(basename "$entry")"
    fi
  done | LC_ALL=C sort -z
}

# ci_archive_serial <archive> prints the serial in the archive's index.json.
ci_archive_serial() {
  local archive="$1" serial
  serial="$(zstd -dc -- "$archive" | tar -xO index.json | jq -er '.serial')" ||
    ci_die "cannot read the serial from $archive"
  case "$serial" in
    '' | *[!0-9]*) ci_die "the serial in $archive is not a non-negative integer" ;;
  esac
  printf '%s\n' "$serial"
}

# ci_verify <archive> <sig> <pubkey> checks the detached raw Ed25519
# signature over the archive bytes.
ci_verify() {
  local archive="$1" sig="$2" pubkey="$3"
  openssl pkeyutl -verify -pubin -inkey "$pubkey" -rawin -in "$archive" -sigfile "$sig" >/dev/null 2>&1
}
