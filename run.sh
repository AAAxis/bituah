#!/usr/bin/env bash
# One command: build, parse the sample policies, write result.json, print the accuracy report.
# Fully offline. Tesseract is only needed for scanned (image-only) PDFs:
#   brew install tesseract tesseract-lang
set -euo pipefail
cd "$(dirname "$0")"
INPUT="${1:-Samples}"
swift build -c release 2>&1 | grep -E "error|warning: unre" || true
BIN=".build/release/bituah"
"$BIN" info
"$BIN" parse "$INPUT" -o result.json
if [ -f ground_truth.json ]; then
  [ -d Samples/variants ] || "$BIN" make-testset Samples --out Samples/variants
  "$BIN" eval --ground-truth ground_truth.json --samples Samples --variants Samples/variants -o metrics.json
fi
# Step 2: rules vs on-device model (Apple Foundation Models) vs hybrid, on both sets. Needs macOS 26+ with Apple Intelligence.
if [ -d Samples/extra ]; then
  [ -d Samples/extra/variants ] || { "$BIN" make-testset Samples/extra --out Samples/extra/variants; rm -f Samples/extra/variants/visual_*; }
  "$BIN" bench -o bench.json
fi
