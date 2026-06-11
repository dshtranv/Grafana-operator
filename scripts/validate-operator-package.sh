#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "Validating dashboard JSON..."
find "$ROOT/grafana/dashboards" -name '*.json' -print0 | while IFS= read -r -d '' f; do
  python3 -m json.tool "$f" >/dev/null
  title=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('title',''))" "$f")
  if [[ -z "$title" ]]; then
    echo "Missing title in $f" >&2
    exit 1
  fi
done

echo "Validating YAML syntax..."
python3 -c "import yaml,pathlib,sys; root=pathlib.Path(sys.argv[1]); [list(yaml.safe_load_all(open(p))) for p in (root/'openshift'/'grafana-operator').rglob('*.yaml')]; print('YAML validation passed')" "$ROOT"
echo "Validation passed"
