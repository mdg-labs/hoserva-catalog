#!/usr/bin/env bash
# Fails unless <sha> is still the tip of <branch> in <repo> on GitHub, so a
# run for an older commit (a queued run, or a re-run of an old one) never
# publishes over a newer one. A failed lookup fails too.
#
# usage: check-tip.sh <owner/repo> <branch> <sha>
#
# Needs gh and GH_TOKEN, as on a GitHub runner.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || ci_die "usage: check-tip.sh <owner/repo> <branch> <sha>"
repo="$1"
branch="$2"
sha="$3"
case "$sha" in
  '' | *[!0-9a-f]*) ci_die "not a commit SHA: $sha" ;;
esac

tip="$(gh api "repos/$repo/git/ref/heads/$branch" --jq .object.sha)" ||
  ci_die "cannot look up the tip of $branch in $repo"
case "$tip" in
  '' | *[!0-9a-f]*) ci_die "the lookup of $branch in $repo returned no commit SHA" ;;
esac
[ "$tip" = "$sha" ] || ci_die "$sha is not the tip of $branch in $repo (now $tip); refusing to publish an older commit"
echo "check-tip: $sha is the tip of $branch"
