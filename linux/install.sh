#!/bin/sh
# session-pet Linux installer — dual-mode, same pattern as tangi's installer.
#
# From a repo clone (linux/face/Cargo.toml next to this script):
#   ./linux/install.sh                    build from source + run now
#   ./linux/install.sh --autostart        + start at every login (XDG autostart)
#
# Without a clone, use the root installer — it works for BOTH OSes and lands
# here on Linux:
#   curl -fsSL https://raw.githubusercontent.com/chud-lori/session-pet/main/install.sh | sh
#   (flags via: ... | sh -s -- --autostart)
#
# Flags:
#   --download          force prebuilt download even inside a clone
#   --from-source       force source build (needs cargo + libgtk-3-dev)
#   --layer-shell       source build only: enable Wayland layer-shell overlay
#   --version vX.Y.Z    download a specific release (default: latest)
#   --autostart         install XDG autostart entry
#   --uninstall         stop the pet, remove binary + autostart entry
#
# Prebuilt binaries need: python3, GTK3 runtime (libgtk-3-0 — present on any
# GNOME/KDE/XFCE desktop). Sound: paplay, pw-play, or ffplay (optional).
set -eu

REPO="chud-lori/session-pet"
BIN_NAME="session-pet"
ASSET_PREFIX="session-pet-linux"
BIN_DIR="${HOME}/.local/bin"
BIN="${BIN_DIR}/${BIN_NAME}"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
DESKTOP="${AUTOSTART_DIR}/session-pet.desktop"

MODE=auto VERSION=latest AUTOSTART=0 FEATURES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --download)    MODE=download ;;
    --from-source) MODE=source ;;
    --layer-shell) FEATURES="--features layer-shell" ;;
    --version)     shift; VERSION="$1" ;;
    --autostart)   AUTOSTART=1 ;;
    --uninstall)
      pkill -x "$BIN_NAME" 2>/dev/null || true
      rm -f "$BIN" "$DESKTOP"
      echo "session-pet uninstalled (state in ~/.local/share/session-pet kept)"
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required (the pet's core is Python)" >&2; exit 1; }

# clone detection: is the source tree sitting next to this script?
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)"
IN_CLONE=0
[ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/face/Cargo.toml" ] && IN_CLONE=1
if [ "$MODE" = auto ]; then
  if [ "$IN_CLONE" = 1 ] && command -v cargo >/dev/null 2>&1; then
    MODE=source
  else
    MODE=download
  fi
fi

mkdir -p "$BIN_DIR"

if [ "$MODE" = source ]; then
  [ "$IN_CLONE" = 1 ] || { echo "error: --from-source needs a repo clone" >&2; exit 1; }
  command -v cargo >/dev/null 2>&1 || { echo "error: cargo not found" >&2; exit 1; }
  pkg-config --exists gtk+-3.0 2>/dev/null || {
    echo "error: GTK3 dev headers missing — sudo apt install libgtk-3-dev" >&2
    [ -n "$FEATURES" ] && echo "       (layer-shell also needs libgtk-layer-shell-dev)" >&2
    exit 1; }
  echo "▸ building face from source"
  # shellcheck disable=SC2086
  (cd "$SCRIPT_DIR/face" && cargo build --release $FEATURES)
  install -m 755 "$SCRIPT_DIR/face/target/release/$BIN_NAME" "$BIN"
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)         ASSET="${ASSET_PREFIX}-x86_64" ;;
    aarch64|arm64)  ASSET="${ASSET_PREFIX}-arm64" ;;
    *) echo "error: unsupported arch $ARCH — use --from-source" >&2; exit 1 ;;
  esac
  if [ "$VERSION" = latest ]; then
    URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
  else
    URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
  fi
  echo "▸ downloading ${ASSET} (${VERSION})"
  TMP="$(mktemp)"
  curl -fSL --progress-bar -o "$TMP" "$URL" || {
    echo "error: download failed — no release published yet? try --from-source" >&2
    rm -f "$TMP"; exit 1; }
  install -m 755 "$TMP" "$BIN"
  rm -f "$TMP"
fi

if [ "$AUTOSTART" = 1 ]; then
  echo "▸ installing autostart entry"
  mkdir -p "$AUTOSTART_DIR"
  cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=session-pet
Comment=desktop companion for your coding agents
Exec=$BIN
X-GNOME-Autostart-enabled=true
EOF
fi

pkill -x "$BIN_NAME" 2>/dev/null || true
nohup "$BIN" >/dev/null 2>&1 &

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" ;;
esac
echo "Done. Click the pet for its panel · drag to move · right-click for menu."
echo "State lives in ~/.local/share/session-pet (or the repo when run from a clone)."
