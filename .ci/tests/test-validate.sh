#!/usr/bin/env bash
# validate.sh with docker and go stubbed on PATH: the pinned lint call, the
# empty catalog, the compose and image checks and their retries, and that a
# failing validation stops the pipeline before any archive exists.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PATH="$ci_root/tests/stubs:$PATH"
export PATH
export STUB_LOG="$T/stub.log"
export CATALOG_IMAGE_ATTEMPTS=3 CATALOG_IMAGE_RETRY_SLEEP=0
pin="$(tr -d '\n' <"$ci_root/hoserva-version")"

reset() {
  : >"$STUB_LOG"
  rm -f "$STUB_LOG.flaky"
  unset STUB_LINT_EXIT STUB_COMPOSE_FAIL STUB_MISSING STUB_BLIP STUB_FLAKY
}

count() { grep -c -- "$1" "$STUB_LOG" || true; }

# A catalog with templates passes: lint from the pinned version, compose
# config per template with a generated env file, a manifest query per image.
reset
expect_ok "$ci_root/validate.sh" "$fixtures/catalog"
assert_eq "$(grep '^go ' "$STUB_LOG")" "go run github.com/mdg-labs/hoserva/cmd/hoserva@$pin template lint $fixtures/catalog" "lint invocation"
assert_eq "$(count 'config --quiet')" 2 "compose config calls"
assert_eq "$(count 'imagetools inspect registry.example/alpha/alpha:1.2.3')" 1 "alpha manifest queries"
assert_eq "$(count 'imagetools inspect registry.example/beta/beta:4.5.6')" 1 "beta manifest queries"
grep -qx "APPDATA='/mnt/cache/appdata'" "$STUB_LOG" || t_fail "an input default is missing from the env file"
grep -qx "WEBUI_PORT='3000'" "$STUB_LOG" || t_fail "an input default is missing from the env file"
grep -qx "MEDIA='/placeholder'" "$STUB_LOG" || t_fail "a default-less path input has no placeholder"
grep -qx "API_SECRET='placeholder'" "$STUB_LOG" || t_fail "a secret input has no placeholder"
grep -qx "TZ='UTC'" "$STUB_LOG" || t_fail "a timezone input has no placeholder"

# An empty catalog skips lint and every other check, and passes.
reset
mkdir "$T/empty"
mkdir "$T/empty/.ci" "$T/empty/.github"
printf 'x' >"$T/empty/README.md"
expect_ok "$ci_root/validate.sh" "$T/empty"
assert_eq "$(wc -c <"$STUB_LOG")" 0 "tools run on an empty catalog"

# A templates/ folder that is missing is an empty catalog; one that is a file
# is refused.
reset
expect_ok "$ci_root/validate.sh" "$T/no-such-templates"
assert_eq "$(wc -c <"$STUB_LOG")" 0 "tools run on a missing templates directory"
printf 'x' >"$T/a-file"
expect_fail "$ci_root/validate.sh" "$T/a-file"

# Without an argument validate.sh checks templates/ of its own checkout, so
# the committed templates are what runs and the repository root is not.
reset
mkdir -p "$T/repo/.ci" "$T/repo/templates"
cp -R "$ci_root/." "$T/repo/.ci/"
cp -R "$fixtures/catalog/." "$T/repo/templates/"
expect_ok "$T/repo/.ci/validate.sh"
assert_eq "$(grep '^go ' "$STUB_LOG")" "go run github.com/mdg-labs/hoserva/cmd/hoserva@$pin template lint $T/repo/.ci/../templates" "default lint target"

# A template directory means lint always runs, and a lint failure stops
# everything before docker is called.
reset
STUB_LINT_EXIT=1 expect_fail "$ci_root/validate.sh" "$fixtures/catalog"
assert_eq "$(count '^go ')" 1 "lint calls"
assert_eq "$(count '^docker ')" 0 "docker calls after a lint failure"

# A symlinked template entry is not mistaken for an empty catalog.
reset
mkdir "$T/linked"
ln -s "$fixtures/catalog/alpha" "$T/linked/alpha"
expect_ok "$ci_root/validate.sh" "$T/linked"
assert_eq "$(count '^go ')" 1 "lint calls on a symlinked entry"
[ ! -e "$fixtures/catalog/alpha/.env" ] || t_fail "validate wrote through a symlinked template into the checkout"
STUB_LINT_EXIT=1 expect_fail "$ci_root/validate.sh" "$T/linked"

# A compose file that does not validate fails.
reset
STUB_COMPOSE_FAIL=1 expect_fail "$ci_root/validate.sh" "$fixtures/catalog"
grep -q 'docker compose config failed' "$T/out" || t_fail "compose failure not reported"

# A missing image fails at once, without retries.
reset
STUB_MISSING=registry.example/beta/beta:4.5.6 expect_fail "$ci_root/validate.sh" "$fixtures/catalog"
assert_eq "$(count 'inspect registry.example/beta/beta:4.5.6')" 1 "queries for a missing image"
grep -q 'does not exist' "$T/out" || t_fail "missing image not reported"

# A registry blip is retried a bounded number of times, then fails.
reset
STUB_BLIP=registry.example/alpha/alpha:1.2.3 expect_fail "$ci_root/validate.sh" "$fixtures/catalog"
assert_eq "$(count 'inspect registry.example/alpha/alpha:1.2.3')" 3 "queries for an unreachable registry"
grep -q 'could not be queried' "$T/out" || t_fail "registry failure not reported"

# A blip that clears within the attempts passes.
reset
STUB_FLAKY=registry.example/alpha/alpha:1.2.3:2 expect_ok "$ci_root/validate.sh" "$fixtures/catalog"
assert_eq "$(count 'inspect registry.example/alpha/alpha:1.2.3')" 3 "queries for a recovering registry"

# The pipeline: a template that fails validation never reaches an archive.
reset
rm -rf "$T/dist"
if STUB_MISSING=registry.example/alpha/alpha:1.2.3 "$ci_root/validate.sh" "$fixtures/catalog" >"$T/out" 2>&1 &&
  "$ci_root/build.sh" "$fixtures/catalog" "$T/dist" >>"$T/out" 2>&1; then
  t_fail "the pipeline passed a catalog that fails validation"
fi
[ ! -e "$T/dist" ] || t_fail "an archive path exists after a failed validation"

# The empty catalog goes through the whole pipeline.
reset
rm -rf "$T/dist"
expect_ok "$ci_root/validate.sh" "$T/empty"
expect_ok "$ci_root/build.sh" "$T/empty" "$T/dist"
[ -f "$T/dist/catalog.tar.zst" ] || t_fail "no archive for the empty catalog"

echo "test-validate: ok"
