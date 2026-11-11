#!/usr/bin/env bash
# Daily CompilerSutra Basic Terminology spotlight (one concept / day).
set -euo pipefail

PIPELINE_ROOT=${PIPELINE_ROOT:-/home/aitr/compilersutra/jenkins_pipeline}
SCRIPT_DIR="$PIPELINE_ROOT/scripts/basic-terminology-daily"
OUT_DIR=${OUT_DIR:-$PIPELINE_ROOT/artifacts/basic-terminology-${BUILD_ID:-local}}
DATE=${DATE:-}
PYTHON_BIN=${PYTHON_BIN:-python3}

mkdir -p "$OUT_DIR"
chmod +x "$SCRIPT_DIR/generate_daily_term.py" 2>/dev/null || true

# PDF output needs fpdf2 (same pattern as live-pdf-daily).
if ! "$PYTHON_BIN" -c 'import fpdf' >/dev/null 2>&1; then
  echo "Installing fpdf2..."
  "$PYTHON_BIN" -m pip install --break-system-packages -q fpdf2 || \
    "$PYTHON_BIN" -m pip install -q fpdf2 || true
fi

ARGS=(--out-dir "$OUT_DIR")
if [ -n "$DATE" ]; then
  ARGS+=(--date "$DATE")
fi

echo "=== Basic Terminology daily bot ==="
echo "OUT_DIR=$OUT_DIR DATE=${DATE:-<today>}"
"$PYTHON_BIN" "$SCRIPT_DIR/generate_daily_term.py" "${ARGS[@]}"

{
  echo "generated=$(date -Is)"
  echo "date=${DATE:-today}"
  echo "files:"
  ls -1 "$OUT_DIR"/* 2>/dev/null || true
} > "$OUT_DIR/STATUS.txt"

echo "Done. Artifacts in $OUT_DIR"
