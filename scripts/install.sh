#!/bin/zsh
# Builds Lanternfish and installs it as /Applications/Lanternfish.app, replacing any
# existing copy (restoring it if the swap fails), then opens it.
#
#   ./scripts/install.sh             build (release), install, open
#   ./scripts/install.sh --dry-run   print what would happen, change nothing
#
# Signing: the app is signed ad-hoc ("-") by default. macOS ties privacy permissions (Local
# Network, Location) to the code signature, and an ad-hoc signature changes with every build,
# so after a reinstall macOS may forget them and ask again. Signing with a stable identity
# avoids that:
#
#   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install.sh
#
# List the identities in your keychain with `security find-identity -p codesigning -v`.
set -euo pipefail
cd "${0:A:h}/.."

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

IDENTITY="${CODESIGN_IDENTITY:--}"
BUILT="build/Lanternfish.app"
DEST="${INSTALL_DEST:-/Applications/Lanternfish.app}"
STAGING="$(dirname "$DEST")/.Lanternfish.app.installing-$$"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

run() {
  if (( DRY_RUN )); then
    print -r -- "+ ${(q)@}"
  else
    "$@"
  fi
}

cleanup() { [[ -e "$STAGING" ]] && rm -rf "$STAGING"; return 0 }
trap cleanup EXIT

echo "==> Building ($([[ $IDENTITY == - ]] && echo ad-hoc || echo "$IDENTITY"))"
run env CODESIGN_IDENTITY="$IDENTITY" APP_OUT="$BUILT" ./scripts/build-app.sh

echo "==> Quitting a running copy"
if (( DRY_RUN )); then
  print -r -- "+ pkill -x Lanternfish"
elif pkill -x Lanternfish; then
  # Give it a moment to exit before its bundle is replaced.
  for _ in {1..20}; do pgrep -x Lanternfish >/dev/null || break; sleep 0.25; done
fi

echo "==> Installing to $DEST"
# Copy next to the destination first (same volume), so the swap below is a rename.
run ditto "$BUILT" "$STAGING"
run codesign --force --options runtime --sign "$IDENTITY" --timestamp=none "$STAGING"
if [[ -e "$DEST" ]]; then
  OLD="$STAGING.old"
  run mv "$DEST" "$OLD"
  # Put the old app back if the new one can't take its place.
  if ! run mv "$STAGING" "$DEST"; then
    run mv "$OLD" "$DEST"
    echo "Install failed; kept the previous version." >&2
    exit 1
  fi
  run rm -rf "$OLD"
else
  run mv "$STAGING" "$DEST"
fi

echo "==> Registering with Launch Services"
run "$LSREGISTER" -f "$DEST"
# Touching the bundle makes Finder and the Dock pick up a changed icon.
run touch "$DEST"

echo "==> Opening"
run open "$DEST"
(( DRY_RUN )) && echo "Dry run: nothing changed." || echo "Installed $DEST"
