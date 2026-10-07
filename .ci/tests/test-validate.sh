#!/usr/bin/env bash
# validate.sh with docker and go stubbed on PATH: the pinned lint call, the
# empty catalog, the description rule, the compose and image checks and their
# retries, and that a failing validation stops the pipeline before any archive
# exists.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PATH="$ci_root/tests/stubs:$PATH"
export PATH
export STUB_LOG="$T/stub.log"
export CATALOG_IMAGE_ATTEMPTS=3 CATALOG_IMAGE_RETRY_SLEEP=0
pin="$(tr -d '\n' <"$ci_root/hoserva-version")"

# The fixture catalog's alpha has no description, which this catalog's rule
# refuses, so every test below that expects a pass uses a copy that has one.
catalog="$T/catalog"
cp -R "$fixtures/catalog" "$catalog"
sed -i '/^  docs:/a\  description: A first test application.' "$catalog/alpha/compose.yaml"

# case_catalog <name> <alpha description lines> copies the fixture catalog to
# $T/<name>, with the given lines (YAML, already indented) after alpha's
# docs line; none given leaves alpha without a description.
case_catalog() {
  local dir="$T/case-$1"
  shift
  rm -rf "$dir"
  cp -R "$fixtures/catalog" "$dir"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"$T/lines"
    sed -i "/^  docs:/r $T/lines" "$dir/alpha/compose.yaml"
  fi
  echo "$dir"
}

# expect_description_refused <catalog> <template id> <diagnostic text> runs
# validate.sh and wants it to fail on the description rule alone: the
# diagnostic names the template and the reason, and neither the compose nor
# the registry stage has run.
expect_description_refused() {
  reset
  expect_fail "$ci_root/validate.sh" "$1"
  grep -F "$2: " "$T/out" | grep -qF "$3" || {
    cat "$T/out" >&2
    t_fail "no diagnostic naming $2 and [$3]"
  }
  grep -q 'description check failed' "$T/out" || t_fail "the description failure is not the one reported"
  assert_eq "$(count '^go ')" 1 "lint calls before a description failure"
  assert_eq "$(count '^docker ')" 0 "docker calls after a description failure"
}

reset() {
  : >"$STUB_LOG"
  rm -f "$STUB_LOG.flaky"
  unset STUB_LINT_EXIT STUB_COMPOSE_FAIL STUB_MISSING STUB_BLIP STUB_FLAKY
}

count() { grep -c -- "$1" "$STUB_LOG" || true; }

# A catalog with templates passes: lint from the pinned version, compose
# config per template with a generated env file, a manifest query per image.
reset
expect_ok "$ci_root/validate.sh" "$catalog"
assert_eq "$(grep '^go ' "$STUB_LOG")" "go run github.com/mdg-labs/hoserva/cmd/hoserva@$pin template lint $catalog" "lint invocation"
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
cp -R "$catalog/." "$T/repo/templates/"
expect_ok "$T/repo/.ci/validate.sh"
assert_eq "$(grep '^go ' "$STUB_LOG")" "go run github.com/mdg-labs/hoserva/cmd/hoserva@$pin template lint $T/repo/.ci/../templates" "default lint target"

# A template meeting the description rule passes, whatever follows its first
# paragraph, and the length is counted in characters, not bytes.
reset
long_second="$(python3 -c "print('x' * 3000, end='')")"
exact="$(python3 -c "print('a' * 300, end='')")"
accented="$(python3 -c "print('\u00e9' * 300, end='')")"
expect_ok "$ci_root/validate.sh" "$(case_catalog ok-short '  description: |-' '    An app.' '' "    $long_second")"
expect_ok "$ci_root/validate.sh" "$(case_catalog ok-300 '  description: |-' "    $exact")"
expect_ok "$ci_root/validate.sh" "$(case_catalog ok-accented '  description: |-' "    $accented")"
expect_ok "$ci_root/validate.sh" "$(case_catalog ok-quoted '  description: "A quoted description."')"

# A template with no description, an empty one or a whitespace-only one fails
# naming the template, before any docker call.
expect_description_refused "$(case_catalog none)" alpha 'x-hoserva.description is missing'
expect_description_refused "$(case_catalog empty '  description: ""')" alpha 'x-hoserva.description is empty'
expect_description_refused "$(case_catalog blank '  description: "  "')" alpha 'x-hoserva.description is empty'
expect_description_refused "$(case_catalog blank-block '  description: |' '    ' '    ')" alpha 'x-hoserva.description is empty'
expect_description_refused "$(case_catalog not-text '  description: 5')" alpha 'x-hoserva.description is not text'

# A first paragraph over 300 characters fails, even when the whole text is
# within the 2000 the schema allows and a short second paragraph follows.
expect_description_refused "$(case_catalog long-one '  description: |-' "    ${exact}b")" alpha 'the first paragraph of x-hoserva.description is 301 characters, more than the 300 allowed'
expect_description_refused "$(case_catalog long-two '  description: |-' "    ${exact}b" '' '    Short.')" alpha 'is 301 characters'
expect_description_refused "$(case_catalog long-accented '  description: |-' "    ${accented}$(python3 -c "print('\u00e9', end='')")")" alpha 'is 301 characters'
expect_description_refused "$(case_catalog long-padded '  description: |' '' "    ${exact}b" '')" alpha 'is 301 characters'

# A short first paragraph does not excuse a template further down the list:
# the failing one is named, the passing one is not.
reset
bad="$(case_catalog second-bad '  description: fine')"
sed -i 's/^  description: |-$/  description: ""/;/^    A beta application\.$/d;/^    Second paragraph\.$/d;/^$/d' "$bad/beta-app/compose.yaml"
expect_fail "$ci_root/validate.sh" "$bad"
grep -qF 'beta-app: x-hoserva.description is empty' "$T/out" || t_fail "beta-app is not named"
! grep -q '^alpha:' "$T/out" || t_fail "a passing template is named"

# A compose file that does not parse, or has no x-hoserva block, fails rather
# than passes.
bad="$(case_catalog no-block '  description: fine')"
printf 'services: {}\n' >"$bad/alpha/compose.yaml"
expect_description_refused "$bad" alpha 'compose.yaml has no x-hoserva block'
bad="$(case_catalog bad-yaml '  description: fine')"
printf 'services: [\n' >"$bad/alpha/compose.yaml"
expect_description_refused "$bad" alpha "cannot read $bad/alpha/compose.yaml"
bad="$(case_catalog no-file '  description: fine')"
rm "$bad/alpha/compose.yaml"
expect_description_refused "$bad" alpha "cannot read $bad/alpha/compose.yaml"

# check-description given no template ids refuses to run rather than
# passing without reading a template.
expect_fail python3 "$ci_root/catalog.py" check-description "$catalog"
grep -q 'usage:' "$T/out" || t_fail "check-description with no ids does not print its usage"

# A template directory means lint always runs, and a lint failure stops
# everything before docker is called.
reset
STUB_LINT_EXIT=1 expect_fail "$ci_root/validate.sh" "$catalog"
assert_eq "$(count '^go ')" 1 "lint calls"
assert_eq "$(count '^docker ')" 0 "docker calls after a lint failure"

# A symlinked template entry is not mistaken for an empty catalog.
reset
mkdir "$T/linked"
ln -s "$catalog/alpha" "$T/linked/alpha"
expect_ok "$ci_root/validate.sh" "$T/linked"
assert_eq "$(count '^go ')" 1 "lint calls on a symlinked entry"
[ ! -e "$catalog/alpha/.env" ] || t_fail "validate wrote through a symlinked template into the checkout"
STUB_LINT_EXIT=1 expect_fail "$ci_root/validate.sh" "$T/linked"

# A compose file that does not validate fails.
reset
STUB_COMPOSE_FAIL=1 expect_fail "$ci_root/validate.sh" "$catalog"
grep -q 'docker compose config failed' "$T/out" || t_fail "compose failure not reported"

# A missing image fails at once, without retries.
reset
STUB_MISSING=registry.example/beta/beta:4.5.6 expect_fail "$ci_root/validate.sh" "$catalog"
assert_eq "$(count 'inspect registry.example/beta/beta:4.5.6')" 1 "queries for a missing image"
grep -q 'does not exist' "$T/out" || t_fail "missing image not reported"

# A registry blip is retried a bounded number of times, then fails.
reset
STUB_BLIP=registry.example/alpha/alpha:1.2.3 expect_fail "$ci_root/validate.sh" "$catalog"
assert_eq "$(count 'inspect registry.example/alpha/alpha:1.2.3')" 3 "queries for an unreachable registry"
grep -q 'could not be queried' "$T/out" || t_fail "registry failure not reported"

# A blip that clears within the attempts passes.
reset
STUB_FLAKY=registry.example/alpha/alpha:1.2.3:2 expect_ok "$ci_root/validate.sh" "$catalog"
assert_eq "$(count 'inspect registry.example/alpha/alpha:1.2.3')" 3 "queries for a recovering registry"

# The pipeline: a template that fails validation never reaches an archive.
reset
rm -rf "$T/dist"
if STUB_MISSING=registry.example/alpha/alpha:1.2.3 "$ci_root/validate.sh" "$catalog" >"$T/out" 2>&1 &&
  "$ci_root/build.sh" "$catalog" "$T/dist" >>"$T/out" 2>&1; then
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
