#!/usr/bin/env bash
set -euo pipefail
find grafana/dashboards -name '*.json' -print0 | while IFS= read -r -d '' file; do
  python3 -m json.tool "$file" >/dev/null
  echo "OK $file"
done
