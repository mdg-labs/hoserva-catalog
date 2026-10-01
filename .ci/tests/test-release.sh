#!/usr/bin/env bash
# check-tip.sh (an older commit never publishes over a newer one) and
# release.sh (the immutable release of a serial), with gh stubbed on PATH.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PATH="$ci_root/tests/stubs:$PATH"
export PATH
export STUB_LOG="$T/stub.log"
repo=mdg-labs/hoserva-catalog
sha=0123456789abcdef0123456789abcdef01234567
newer=fedcba9876543210fedcba9876543210fedcba98

reset() {
  : >"$STUB_LOG"
  unset STUB_TIP STUB_LOOKUP_FAIL STUB_TAGS STUB_RELEASE_FAIL
}

# The tip check: only the exact tip passes; a moved tip and a failed lookup fail.
reset
export STUB_TIP="$sha"
expect_ok "$ci_root/check-tip.sh" "$repo" main "$sha"
grep -qx "gh api repos/$repo/git/ref/heads/main --jq .object.sha" "$STUB_LOG" || t_fail "the tip lookup is not the branch ref"

reset
export STUB_TIP="$newer"
expect_fail "$ci_root/check-tip.sh" "$repo" main "$sha"
grep -q 'not the tip' "$T/out" || t_fail "the tip check did not say why it refused"

reset
export STUB_TIP="$sha" STUB_LOOKUP_FAIL=1
expect_fail "$ci_root/check-tip.sh" "$repo" main "$sha"

reset
export STUB_TIP="not-a-sha"
expect_fail "$ci_root/check-tip.sh" "$repo" main "$sha"
reset
export STUB_TIP=""
expect_fail "$ci_root/check-tip.sh" "$repo" main "$sha"
reset
export STUB_TIP="$sha"
expect_fail "$ci_root/check-tip.sh" "$repo" main "refs/heads/main"

# The release: a verified archive, tag serial-<serial>, targeting the commit,
# with the archive and its signature as the only assets.
gen_key good
gen_key other
expect_ok "$ci_root/build.sh" "$fixtures/catalog" "$T/dist"
HOSERVA_CATALOG_SIGNING_KEY="$(cat "$T/good.key")" expect_ok "$ci_root/sign.sh" \
  "$T/dist/catalog.tar.zst" "$T/dist/catalog.tar.zst.sig" "$T/good.pub"
serial="$(zstd -dc -- "$T/dist/catalog.tar.zst" | tar -xO index.json | jq -r .serial)"

reset
expect_ok "$ci_root/release.sh" "$repo" "$sha" "$T/dist" "$T/good.pub"
assert_eq "$(grep -c '^gh release create' "$STUB_LOG")" 1 "release create calls"
assert_eq "$(grep '^gh release create' "$STUB_LOG")" \
  "gh release create serial-$serial --repo $repo --target $sha --title Catalog serial $serial --notes The signed catalog archive with serial $serial, exactly as published at catalog.hoserva.dev. $T/dist/catalog.tar.zst $T/dist/catalog.tar.zst.sig" "release create call"

# An existing tag is never overwritten or re-uploaded, whatever else it holds.
reset
export STUB_TAGS="serial-1,serial-$serial"
expect_fail "$ci_root/release.sh" "$repo" "$sha" "$T/dist" "$T/good.pub"
grep -q 'already exists' "$T/out" || t_fail "release.sh did not say the tag exists"
assert_eq "$(grep -c '^gh release' "$STUB_LOG" || true)" 0 "release calls for an existing tag"

# A lookup error is not read as "the tag is free".
reset
export STUB_LOOKUP_FAIL=1
expect_fail "$ci_root/release.sh" "$repo" "$sha" "$T/dist" "$T/good.pub"
assert_eq "$(grep -c '^gh release' "$STUB_LOG" || true)" 0 "release calls after a failed lookup"

# A failing gh release create fails the script.
reset
export STUB_RELEASE_FAIL=1
expect_fail "$ci_root/release.sh" "$repo" "$sha" "$T/dist" "$T/good.pub"

# An archive that does not verify, or was altered after signing, is never released.
reset
expect_fail "$ci_root/release.sh" "$repo" "$sha" "$T/dist" "$T/other.pub"
cp -R "$T/dist" "$T/altered"
printf 'x' >>"$T/altered/catalog.tar.zst"
expect_fail "$ci_root/release.sh" "$repo" "$sha" "$T/altered" "$T/good.pub"
rm "$T/dist/catalog.tar.zst.sig"
expect_fail "$ci_root/release.sh" "$repo" "$sha" "$T/dist" "$T/good.pub"
assert_eq "$(grep -c '^gh ' "$STUB_LOG" || true)" 0 "gh calls for an archive that does not verify"
reset
expect_fail "$ci_root/release.sh" "$repo" "refs/heads/main" "$T/dist" "$T/good.pub"

echo "test-release: ok"
