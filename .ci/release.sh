#!/usr/bin/env bash
# Publishes a signed archive as the immutable GitHub Release
# serial-<serial> of <owner/repo>, targeting <sha>, with the archive and its
# signature as the only assets. The signature is verified first, and a tag
# that already exists is never touched: the run fails instead.
#
# usage: release.sh <owner/repo> <sha> <dist-dir> <public-key.pem>
#
# <dist-dir> holds catalog.tar.zst and catalog.tar.zst.sig. Needs gh and
# GH_TOKEN, as on a GitHub runner.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 4 ] || ci_die "usage: release.sh <owner/repo> <sha> <dist-dir> <public-key.pem>"
repo="$1"
sha="$2"
dist="$3"
pubkey="$4"
case "$sha" in
  '' | *[!0-9a-f]*) ci_die "not a commit SHA: $sha" ;;
esac

serial="$("$ci_dir/verify.sh" "$dist/catalog.tar.zst" "$dist/catalog.tar.zst.sig" "$pubkey")" ||
  ci_die "the archive in $dist does not verify; not releasing it"
tag="serial-$serial"

# A 404 is the only answer that means the tag is free.
if lookup="$(gh api "repos/$repo/git/ref/tags/$tag" 2>&1)"; then
  ci_die "the tag $tag already exists in $repo; never overwriting it"
fi
case "$lookup" in
  *"HTTP 404"*) ;;
  *) ci_die "cannot tell whether the tag $tag exists in $repo: $lookup" ;;
esac

gh release create "$tag" --repo "$repo" --target "$sha" \
  --title "Catalog serial $serial" \
  --notes "The signed catalog archive with serial $serial, exactly as published at catalog.hoserva.dev." \
  "$dist/catalog.tar.zst" "$dist/catalog.tar.zst.sig"
echo "release: created $tag in $repo"
