#!/usr/bin/env bash
# build.sh: archive contents, index.json fields, content hash, empty
# catalog, a rising serial, and refusal of anything but plain files.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

listing() { zstd -dc -- "$1" | tar -t; }
index() { zstd -dc -- "$1" | tar -xO index.json; }

# The expected hash, computed with sha256sum rather than catalog.py.
expected_hash() {
  local dir="$1" file
  (
    cd "$dir" || exit 1
    while IFS= read -r file; do
      printf '%s\0%s\0' "$file" "$(wc -c <"$file")"
      cat -- "$file"
    done < <(find . -type f -printf '%P\n' | LC_ALL=C sort)
  ) | sha256sum | cut -d' ' -f1
}

# Fixture catalog: contents and index.json.
expect_ok "$ci_root/build.sh" "$fixtures/catalog" "$T/out1"
archive="$T/out1/catalog.tar.zst"
assert_eq "$(listing "$archive")" "index.json
alpha/
alpha/compose.yaml
alpha/icon.svg
beta-app/
beta-app/compose.yaml
beta-app/logo.png" "archive entries"

serial="$(index "$archive" | jq -r .serial)"
assert_eq "$(index "$archive" | jq -r .schema)" 1 "index schema"
assert_eq "$(index "$archive" | jq -r '.generatedAt')" "$(date -u -d "@$serial" +%Y-%m-%dT%H:%M:%SZ)" "generatedAt"
assert_eq "$(index "$archive" | jq -r '.templates | map(.id) | join(",")')" "alpha,beta-app" "template ids"
assert_eq "$(index "$archive" | jq -c '.templates[0] | del(.contentHash)')" \
  '{"id":"alpha","revision":2,"title":"Alpha","categories":["tools"],"icon":"icon.svg","docs":"https://docs.example/alpha/"}' "alpha entry"
assert_eq "$(index "$archive" | jq -c '.templates[1] | del(.contentHash)')" \
  '{"id":"beta-app","revision":1,"title":"Beta App","categories":["media","tools"],"icon":"logo.png","docs":"https://docs.example/beta/"}' "beta-app entry"
assert_eq "$(index "$archive" | jq -r '.templates[0].contentHash')" "$(expected_hash "$fixtures/catalog/alpha")" "alpha content hash"
assert_eq "$(index "$archive" | jq -r '.templates[1].contentHash')" "$(expected_hash "$fixtures/catalog/beta-app")" "beta-app content hash"

# Normalised owner, mode and mtime.
zstd -dc -- "$archive" | TZ=UTC tar --numeric-owner --full-time -tv >"$T/verbose"
bad="$(grep -vcE "^(-rw-r--r--|drwxr-xr-x) 0/0 +[0-9]+ $(date -u -d "@$serial" '+%Y-%m-%d %H:%M:%S')" "$T/verbose" || true)"
assert_eq "$bad" 0 "entries without normalised owner, mode and mtime"

# An execute bit in the checkout does not reach the archive.
cp -R "$fixtures/catalog" "$T/exec"
chmod 0755 "$T/exec/alpha/icon.svg" "$T/exec/alpha/compose.yaml"
expect_ok "$ci_root/build.sh" "$T/exec" "$T/out-exec"
zstd -dc -- "$T/out-exec/catalog.tar.zst" | tar --numeric-owner -tv >"$T/verbose-exec"
bad="$(grep -vcE '^(-rw-r--r--|drwxr-xr-x) 0/0 ' "$T/verbose-exec" || true)"
assert_eq "$bad" 0 "entries with a mode other than 0644 or 0755 (directories)"
assert_eq "$(index "$T/out-exec/catalog.tar.zst" | jq -r '.templates[0].contentHash')" "$(index "$archive" | jq -r '.templates[0].contentHash')" "content hash ignores modes"

# A change to a template's file changes only its own content hash.
cp -R "$fixtures/catalog" "$T/changed"
printf '# extra\n' >>"$T/changed/alpha/compose.yaml"
expect_ok "$ci_root/build.sh" "$T/changed" "$T/out-changed"
assert_eq "$(index "$T/out-changed/catalog.tar.zst" | jq -r '.templates[1].contentHash')" "$(index "$archive" | jq -r '.templates[1].contentHash')" "untouched template hash"
[ "$(index "$T/out-changed/catalog.tar.zst" | jq -r '.templates[0].contentHash')" != "$(index "$archive" | jq -r '.templates[0].contentHash')" ] ||
  t_fail "changed template kept its content hash"

# Only template directories go in: dot directories and root files stay out.
mkdir -p "$T/mixed/.ci" "$T/mixed/.github"
cp -R "$fixtures/catalog/alpha" "$T/mixed/alpha"
printf 'x' >"$T/mixed/README.md"
printf 'x' >"$T/mixed/.ci/tool.sh"
expect_ok "$ci_root/build.sh" "$T/mixed" "$T/out-mixed"
assert_eq "$(listing "$T/out-mixed/catalog.tar.zst")" "index.json
alpha/
alpha/compose.yaml
alpha/icon.svg" "mixed catalog entries"

# Empty catalog: an archive holding an index with no templates.
mkdir "$T/empty"
expect_ok "$ci_root/build.sh" "$T/empty" "$T/out-empty"
assert_eq "$(listing "$T/out-empty/catalog.tar.zst")" "index.json" "empty catalog entries"
assert_eq "$(index "$T/out-empty/catalog.tar.zst" | jq -c .templates)" "[]" "empty catalog templates"
assert_eq "$(index "$T/out-empty/catalog.tar.zst" | jq -r .schema)" 1 "empty catalog schema"

# The serial rises on a rebuild of an unchanged catalog.
sleep 1
expect_ok "$ci_root/build.sh" "$fixtures/catalog" "$T/out2"
serial2="$(index "$T/out2/catalog.tar.zst" | jq -r .serial)"
[ "$serial2" -gt "$serial" ] || t_fail "rebuild serial $serial2 is not higher than $serial"

# A stale signature never survives a rebuild.
printf 'stale' >"$T/out2/catalog.tar.zst.sig"
expect_ok "$ci_root/build.sh" "$fixtures/catalog" "$T/out2"
[ ! -e "$T/out2/catalog.tar.zst.sig" ] || t_fail "build left a stale signature"

# Anything but plain files in a template fails the build and leaves no archive.
cp -R "$fixtures/catalog/alpha" "$T/linked-src"
mkdir "$T/linked"
mv "$T/linked-src" "$T/linked/alpha"
ln -s /etc/hostname "$T/linked/alpha/leak"
expect_fail "$ci_root/build.sh" "$T/linked" "$T/out-linked"
[ ! -e "$T/out-linked/catalog.tar.zst" ] || t_fail "build wrote an archive over a symlink"
assert_eq "$(find "$T/out-linked" -type f | wc -l)" 0 "files left by the failed build"

echo "test-build: ok"
