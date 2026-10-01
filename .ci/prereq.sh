#!/usr/bin/env bash
# Fails, naming what is missing, unless every tool the catalog scripts need
# is on PATH, plus any tools named as arguments (the validation job adds docker).
set -euo pipefail

missing=()
for tool in curl jq openssl python3 tar zstd "$@"; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
python3 -c 'import yaml' 2>/dev/null || missing+=("python3 module yaml (PyYAML)")

if [ "${#missing[@]}" -gt 0 ]; then
  echo "prereq: missing: ${missing[*]}" >&2
  exit 1
fi
