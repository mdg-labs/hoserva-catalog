#!/usr/bin/env bash
# Runs every tooling test and fails if any of them does.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$here/../prereq.sh"

failed=0
for t in "$here"/test-*.sh; do
  if ! bash "$t"; then
    echo "FAILED: $(basename "$t")" >&2
    failed=1
  fi
done
exit "$failed"
