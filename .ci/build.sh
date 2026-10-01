#!/usr/bin/env bash
# Builds <out-dir>/catalog.tar.zst from the template directories in
# <templates-dir> (templates/ of the checkout): index.json plus every <id>/
# directory at the archive root, sorted, with owner, mode and mtime
# normalised. The archive never contains the templates/ folder itself. A
# missing templates directory builds an archive with no templates. The
# serial is the build's Unix time. Run only after validate.sh has passed.
#
# usage: build.sh <templates-dir> <out-dir>
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 2 ] || ci_die "usage: build.sh <templates-dir> <out-dir>"
catalog="$1"
out="$2"
if [ -e "$catalog" ] || [ -L "$catalog" ]; then
  [ -d "$catalog" ] || ci_die "not a directory: $catalog"
fi

ids=()
while IFS= read -r -d '' entry; do
  if [ ! -d "$catalog/$entry" ] || [ -L "$catalog/$entry" ]; then
    ci_die "$entry is not a plain directory"
  fi
  ids+=("$entry")
done < <(ci_entries "$catalog")

stage="$(mktemp -d)"
mkdir -p "$out"
rm -f -- "$out/catalog.tar.zst" "$out/catalog.tar.zst.sig"
partial="$(mktemp "$out/.catalog.tar.zst.XXXXXX")"
trap 'rm -rf "$stage" "$partial"' EXIT

for id in "${ids[@]}"; do
  if [ -n "$(find "$catalog/$id" ! -type f ! -type d -print -quit)" ]; then
    ci_die "$id holds something other than regular files and directories"
  fi
  cp -R -- "$catalog/$id" "$stage/$id"
done

serial="$(date +%s)"
python3 "$ci_dir/catalog.py" index "$stage" "$serial" "${ids[@]}" >"$stage/index.json"

# Modes are set here, not left to the checkout or the umask: tar's --mode
# below keeps an execute bit a file already has.
find "$stage" -type d -exec chmod 0755 {} +
find "$stage" -type f -exec chmod 0644 {} +

tar --create --file=- --directory="$stage" --sort=name --owner=0 --group=0 --numeric-owner \
  --mtime="@$serial" --mode='u=rwX,go=rX' index.json "${ids[@]}" | zstd -19 -T1 -q -o "$partial" -f

chmod 0644 "$partial"
mv -- "$partial" "$out/catalog.tar.zst"
echo "built $out/catalog.tar.zst with serial $serial and ${#ids[@]} template(s)"
