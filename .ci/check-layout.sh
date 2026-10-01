#!/usr/bin/env bash
# Fails when a template directory sits anywhere but templates/: CI validates
# and builds templates/ only, so a directory a contributor adds at the
# repository root would otherwise be skipped without a word. Dot directories
# (.ci, .github) and files are not template directories.
#
# usage: check-layout.sh [repo-root]   (default: this checkout)
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root="${1:-$ci_dir/..}"
[ -d "$root" ] || ci_die "not a directory: $root"

if [ -L "$root/templates" ] || { [ -e "$root/templates" ] && [ ! -d "$root/templates" ]; }; then
  ci_die "templates must be a plain directory"
fi

stray=()
while IFS= read -r -d '' entry; do
  [ "$entry" = templates ] || stray+=("$entry")
done < <(ci_entries "$root")

if [ "${#stray[@]}" -gt 0 ]; then
  echo "check-layout: directories outside templates/ are never validated or built:" >&2
  printf '  %s\n' "${stray[@]}" >&2
  ci_die "move each template to templates/<id>/"
fi
echo "check-layout: ok"
