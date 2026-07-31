#!/usr/bin/env bash
# CI-friendly grammar bootstrap: validate pins then materialize Grammars/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/check-grammar-pins.sh
./scripts/update-grammars.sh
