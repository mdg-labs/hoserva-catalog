#!/usr/bin/env bash
# Validates the templates directory of a catalog checkout: `hoserva template
# lint` from the pinned Hoserva version, then per template `docker compose
# config` and a manifest query for every image. Exits non-zero on the first
# failing stage; an empty or missing templates directory skips lint, which
# would otherwise report "no template directories found" (git does not keep
# an empty directory, so a catalog without templates has none).
#
# usage: validate.sh [templates-dir]   (default: templates/ of this checkout)
#
# check-layout.sh is the separate check that nothing else at the repository
# root is a template directory.
#
# CATALOG_IMAGE_ATTEMPTS (default 3) and CATALOG_IMAGE_RETRY_SLEEP
# (default 5, seconds) bound the manifest query's retries.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

catalog="${1:-$ci_dir/../templates}"
attempts="${CATALOG_IMAGE_ATTEMPTS:-3}"
retry_sleep="${CATALOG_IMAGE_RETRY_SLEEP:-5}"

if [ -e "$catalog" ] || [ -L "$catalog" ]; then
  [ -d "$catalog" ] || ci_die "not a directory: $catalog"
fi

IFS= read -r version <"$ci_dir/hoserva-version" || [ -n "$version" ] || ci_die "cannot read $ci_dir/hoserva-version"
case "$version" in
  '' | -* | *[!A-Za-z0-9._-]*) ci_die "$ci_dir/hoserva-version must hold one commit SHA or tag" ;;
esac

entries=()
while IFS= read -r -d '' entry; do
  entries+=("$entry")
done < <(ci_entries "$catalog")

if [ "${#entries[@]}" -eq 0 ]; then
  echo "validate: the catalog has no template directory; skipping lint, nothing to check"
  exit 0
fi

go run "github.com/mdg-labs/hoserva/cmd/hoserva@$version" template lint "$catalog"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A manifest the registry reports missing fails at once; any other failure
# is retried, so a registry blip is not read as a missing tag.
check_image() {
  local image="$1" try out
  for ((try = 1; try <= attempts; try++)); do
    if out="$(docker buildx imagetools inspect "$image" 2>&1)"; then
      return 0
    fi
    if grep -qiE 'not found|manifest unknown|name unknown|no such manifest' <<<"$out"; then
      echo "validate: image $image does not exist:" >&2
      printf '  %s\n' "${out//$'\n'/$'\n'  }" >&2
      return 1
    fi
    if [ "$try" -lt "$attempts" ]; then
      sleep "$retry_sleep"
    fi
  done
  echo "validate: image $image could not be queried after $attempts attempts:" >&2
  printf '  %s\n' "${out//$'\n'/$'\n'  }" >&2
  return 1
}

failed=0
for id in "${entries[@]}"; do
  copy="$work/$id"
  mkdir "$copy"
  cp -R -- "$catalog/$id/." "$copy/"
  python3 "$ci_dir/catalog.py" env "$copy/compose.yaml" >"$copy/.env"
  compose=(docker compose --project-name catalog-check --project-directory "$copy" -f "$copy/compose.yaml" --env-file "$copy/.env")

  if ! "${compose[@]}" config --quiet; then
    echo "validate: $id: docker compose config failed" >&2
    failed=1
    continue
  fi
  images="$("${compose[@]}" config --images)"
  template_ok=1
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    check_image "$image" || template_ok=0
  done < <(LC_ALL=C sort -u <<<"$images")
  if [ "$template_ok" -eq 1 ]; then
    echo "validate: $id checked"
  else
    failed=1
  fi
done

[ "$failed" -eq 0 ] || ci_die "validation failed"
