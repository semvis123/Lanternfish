#!/bin/zsh
# Renders the README screenshots (docs/images/*.png) from Lanternfish's built-in demo network.
# No real network data is used: LANTERNFISH_PREVIEW=1 swaps in made-up devices, LANTERNFISH_WIFI_DEMO=1
# made-up Wi-Fi networks, and LANTERNFISH_DATA_DIR points at an empty, throwaway history.
#
#   ./scripts/screenshots.sh            build (with debug hooks) and render every image
#   ./scripts/screenshots.sh map        render only images whose name contains "map"
#   SKIP_BUILD=1 ./scripts/screenshots.sh
#
# Each image is rendered in light and dark (name.png / name-dark.png).
set -euo pipefail
cd "${0:A:h}/.."

FILTER="${1:-}"
OUT="docs/images"
APP="build/Lanternfish.app"
WORK="$(mktemp -d)"
trap 'pkill -x Lanternfish 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  DEBUG_HOOKS=1 ./scripts/build-app.sh
fi

# save <png> <path without extension>: the map's soft gradients compress badly as PNG, so it's
# saved as JPEG; other images stay PNG (losslessly shrunk with oxipng when it's installed).
save() {
  local src="$1" dest="$2"
  rm -f "$dest.png" "$dest.jpg"
  if [[ "${dest:t}" == map* ]]; then
    sips -s format jpeg -s formatOptions 88 "$src" --out "$dest.jpg" >/dev/null
    echo "  $dest.jpg"
  else
    cp "$src" "$dest.png"
    command -v oxipng >/dev/null && oxipng -o 3 --strip safe -q "$dest.png"
    echo "  $dest.png"
  fi
}

# shot <name> <env…>: launches the app with LANTERNFISH_PREVIEW and the given LANTERNFISH_* variables in light
# and dark, waits for the snapshot hook to write $SNAP, and quits the app.
shot() {
  local name="$1"; shift
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  local appearance suffix file kv args
  for appearance in light dark; do
    suffix=$([[ $appearance == dark ]] && echo "-dark" || echo "")
    file="$WORK/$name$suffix.png"
    rm -rf "$WORK/data" && mkdir -p "$WORK/data"
    args=(--env LANTERNFISH_DATA_DIR="$WORK/data" --env LANTERNFISH_PREVIEW=1 --env LANTERNFISH_APPEARANCE="$appearance")
    for kv in "$@"; do args+=(--env "${kv//\$SNAP/$file}"); done
    open -n "${args[@]}" "$APP"
    for _ in {1..120}; do [[ -s "$file" ]] && break; sleep 0.25; done
    sleep 0.5
    pkill -x Lanternfish || true
    for _ in {1..20}; do pgrep -x Lanternfish >/dev/null || break; sleep 0.25; done
    if [[ -s "$file" ]]; then
      save "$file" "$OUT/$name$suffix"
    else
      echo "  FAILED: $name ($appearance)" >&2
      return 1
    fi
  done
}

echo "==> Rendering screenshots"
shot devices  'LANTERNFISH_PREVIEW_SELECT=192.168.1.10' 'LANTERNFISH_SNAPSHOT=$SNAP' 'LANTERNFISH_SNAPSHOT_DELAY=4'
shot map      'LANTERNFISH_VIEW=map' 'LANTERNFISH_MAP_SNAPSHOT=$SNAP' 'LANTERNFISH_MAP_SNAPSHOT_SIZE=1100x720' \
              'LANTERNFISH_MAP_SNAPSHOT_SELECT=192.168.1.10'
shot airwaves 'LANTERNFISH_WIFI_DEMO=1' 'LANTERNFISH_AIRWAVES=1' 'LANTERNFISH_WIFI_SNAPSHOT=$SNAP' 'LANTERNFISH_WIFI_SELECT=Harbor'
shot overview 'LANTERNFISH_HEALTH=overview' 'LANTERNFISH_HEALTH_SNAPSHOT=$SNAP' 'LANTERNFISH_HEALTH_SNAPSHOT_DELAY=4'
shot health   'LANTERNFISH_HEALTH=1' 'LANTERNFISH_HEALTH_SNAPSHOT=$SNAP' 'LANTERNFISH_HEALTH_SNAPSHOT_DELAY=4'
shot palette  'LANTERNFISH_PALETTE=liv' 'LANTERNFISH_SNAPSHOT=$SNAP' 'LANTERNFISH_SNAPSHOT_DELAY=4'
shot menubar  'LANTERNFISH_WATCH_IPS=192.168.1.10,192.168.1.70' 'LANTERNFISH_MENUBAR_SNAPSHOT=$SNAP' \
              'LANTERNFISH_MENUBAR_SNAPSHOT_DELAY=4'
echo "Done."
