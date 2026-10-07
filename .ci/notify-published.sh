#!/usr/bin/env bash
# After a catalog publish: asks <owner/repo> (the Hoserva repository) to
# rebuild hoserva.dev, so /apps lists the new catalog within minutes. It sends
# one repository_dispatch, event type catalog-published, with the serial in
# client_payload.
#
# usage: notify-published.sh <owner/repo> <serial>
#
# This is the one step that never fails a publish: the catalog is already
# served, and the site's daily rebuild catches up. A missing or empty GH_TOKEN
# (a personal access token that may send repository_dispatch to <owner/repo>)
# or a failed call is a ::warning:: and exit 0. The token is read from the
# environment only, never put on a command line or printed. Needs gh and jq.
# CATALOG_NOTIFY_TIMEOUT (default 60, seconds) bounds the call.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 2 ] || ci_die "usage: notify-published.sh <owner/repo> <serial>"
repo="$1"
serial="$2"
case "$serial" in
  '' | *[!0-9]*) ci_die "the serial is not a non-negative integer: $serial" ;;
esac

warn() {
  printf '::warning title=hoserva.dev rebuild not requested::%s\n' "$*"
  exit 0
}

[ -n "${GH_TOKEN:-}" ] || warn "the GH_TOKEN secret is not set, so $repo was not asked to rebuild hoserva.dev; the daily rebuild picks up serial $serial"

body="$(jq -nc --arg serial "$serial" '{event_type: "catalog-published", client_payload: {serial: $serial}}')" ||
  warn "could not build the dispatch request; the daily rebuild picks up serial $serial"

if out="$(timeout "${CATALOG_NOTIFY_TIMEOUT:-60}" gh api --method POST "repos/$repo/dispatches" --input - <<<"$body" 2>&1)"; then
  echo "notify-published: asked $repo to rebuild hoserva.dev for serial $serial"
  exit 0
fi
out="$(printf '%s' "$out" | tr '\n\r' '  ')"
warn "the catalog-published dispatch to $repo failed (${out:-no output}); the daily rebuild picks up serial $serial"
