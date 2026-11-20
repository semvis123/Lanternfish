#!/usr/bin/env bash
# Regenerates Sources/LanternfishKit/Resources/oui.tsv from the IEEE MA-L registry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/Sources/LanternfishKit/Resources/oui.tsv"
URL="https://standards-oui.ieee.org/oui/oui.csv"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL ..."
curl -fsSL --retry 3 -A "Lanternfish-oui-fetch" -o "$TMP/oui.csv" "$URL"

# -I: isolated mode, so nothing next to the downloaded file can be imported.
python3 -I "$SCRIPT_DIR/oui_clean.py" "$TMP/oui.csv" "$TMP/oui.tsv"
mv "$TMP/oui.tsv" "$OUT"
echo "Done: $(wc -l < "$OUT" | tr -d ' ') lines -> $OUT"
