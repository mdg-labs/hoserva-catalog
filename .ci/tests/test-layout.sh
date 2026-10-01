#!/usr/bin/env bash
# check-layout.sh: templates live in templates/ and nowhere else at the
# repository root, so a directory CI would silently skip is refused.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

repo() {
  rm -rf "$T/repo"
  mkdir -p "$T/repo/templates" "$T/repo/.ci" "$T/repo/.github"
  cp -R "$fixtures/catalog/." "$T/repo/templates/"
  printf 'x' >"$T/repo/README.md"
}

# Templates under templates/, with dot directories and root files, pass.
repo
expect_ok "$ci_root/check-layout.sh" "$T/repo"

# A repository with no templates/ folder passes: git keeps no empty directory.
repo
rm -rf "$T/repo/templates"
expect_ok "$ci_root/check-layout.sh" "$T/repo"

# A template directory left at the root fails and is named.
repo
cp -R "$fixtures/catalog/alpha" "$T/repo/stray-app"
expect_fail "$ci_root/check-layout.sh" "$T/repo"
grep -q 'stray-app' "$T/out" || t_fail "the stray directory is not named"
grep -q 'templates/<id>/' "$T/out" || t_fail "the fix is not stated"

# So does a stray directory with no compose file, and a symlink to a directory.
repo
mkdir "$T/repo/docs"
expect_fail "$ci_root/check-layout.sh" "$T/repo"
repo
ln -s "$T/repo/templates/alpha" "$T/repo/linked-app"
expect_fail "$ci_root/check-layout.sh" "$T/repo"

# templates must be a plain directory.
repo
rm -rf "$T/repo/templates"
printf 'x' >"$T/repo/templates"
expect_fail "$ci_root/check-layout.sh" "$T/repo"
repo
mv "$T/repo/templates" "$T/real-templates"
ln -s "$T/real-templates" "$T/repo/templates"
expect_fail "$ci_root/check-layout.sh" "$T/repo"

# The default is this checkout, which must itself be laid out correctly.
expect_ok "$ci_root/check-layout.sh"

echo "test-layout: ok"
