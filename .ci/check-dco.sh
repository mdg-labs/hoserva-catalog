#!/usr/bin/env bash
# Verify every non-merge commit in (base, head] carries a Signed-off-by
# trailer matching its own author's email (CONTRIBUTING.md, Q2, Q35).
#
# Merge commits are skipped: they carry no diff of their own, and the
# commits they merge are checked individually. Trailers are parsed with git's
# own `%(trailers:...)` format, not a message-body regex.
#
# Anything that stops the range from being walked is a failure, never a pass:
# an unknown base or head (a shallow clone), or a failing `git rev-list`.
set -euo pipefail

die() { printf 'check-dco: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $0 <base-sha> <head-sha>"
base=$1
head=$2

[ -n "$head" ] || die "no head commit given"
git rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "head '$head' is not a known commit (shallow clone? fetch-depth: 0 is required)"

# A new branch's push carries an all-zero `before` SHA: there is no base to
# range from, so every commit reachable from head is checked.
case "$base" in
  0000000000000000000000000000000000000000) range="$head" ;;
  "") die "no base commit given" ;;
  *)
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base '$base' is not a known commit (shallow clone? fetch-depth: 0 is required)"
    range="$base..$head"
    ;;
esac

commits=$(git rev-list --no-merges "$range") || die "cannot list the commits in $range"

fail=0
checked=0
while read -r sha; do
  [ -n "$sha" ] || continue
  checked=$((checked + 1))
  author_email=$(git log -1 --format='%ae' "$sha")
  signoffs=$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$sha")
  if [ -z "$signoffs" ]; then
    printf 'check-dco: %s (%s) has no Signed-off-by trailer\n' "$sha" "$author_email" >&2
    fail=1
    continue
  fi
  if ! printf '%s\n' "$signoffs" | grep -qiF "<$author_email>"; then
    printf 'check-dco: %s (%s) has a Signed-off-by trailer that does not match its author email\n' "$sha" "$author_email" >&2
    fail=1
  fi
done <<<"$commits"

printf 'check-dco: %d commit(s) checked in %s\n' "$checked" "$range"
exit "$fail"
