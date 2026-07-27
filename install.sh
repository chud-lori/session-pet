#!/bin/sh
# session-pet installer — one tool, macOS + Linux, one entry point.
#
# From a clone:
#   ./install.sh                 build + run now
#   ./install.sh --login-item    + start at every login (LaunchAgent / XDG)
#   ./install.sh --uninstall     stop the pet, remove the login entry
#
# Without a clone (either OS — downloads a prebuilt from GitHub Releases):
#   curl -fsSL https://raw.githubusercontent.com/chud-lori/session-pet/main/install.sh | sh
#   (flags via: ... | sh -s -- --login-item)
#
# POSIX sh on purpose: the one-liner pipes into `sh`, which is dash on
# Debian/Ubuntu — no bashisms (pipefail, [[ ]], arrays) allowed here.
# Requirements: python3. Clone builds also need swiftc (macOS) / cargo (Linux).
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO="chud-lori/session-pet"

# Linux: hand over to the Linux half (Rust face + Python core, same flags).
# --login-item is the mac spelling; map it to the XDG equivalent by
# rotating "$@" once through the translator.
if [ "$(uname -s)" = "Linux" ]; then
  n=$#
  i=0
  while [ "$i" -lt "$n" ]; do
    a=$1
    shift
    [ "$a" = "--login-item" ] && a="--autostart"
    set -- "$@" "$a"
    i=$((i + 1))
  done
  if [ -f "$ROOT/linux/install.sh" ]; then
    exec "$ROOT/linux/install.sh" "$@"
  fi
  # curl | sh outside a clone: fetch the Linux installer and continue there
  tmp="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/linux/install.sh" -o "$tmp"
  rc=0
  sh "$tmp" "$@" || rc=$?
  rm -f "$tmp"
  exit $rc
fi
PLIST="$HOME/Library/LaunchAgents/com.session-pet.plist"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  pkill -x SessionPet 2>/dev/null || true
  echo "session-pet uninstalled (repo and pet state left untouched)"
  exit 0
fi

if [ -d "$ROOT/native/src" ]; then
  BIN="$ROOT/native/SessionPet"
  mkdir -p "$ROOT/.state"  # fresh clones ship without it; the pet/hook need it

  echo "▸ exporting sprite assets"
  python3 "$ROOT/native/export_assets.py"

  echo "▸ building native pet"
  swiftc -O "$ROOT"/native/src/*.swift -o "$BIN"
else
  # curl | sh without a clone: prebuilt universal binary + assets tarball,
  # unpacked to the same layout the app expects (state lives inside it)
  ROOT="$HOME/.local/share/session-pet"
  BIN="$ROOT/native/SessionPet"
  echo "▸ downloading prebuilt universal binary"
  mkdir -p "$ROOT/.state"
  TARBALL="$(mktemp)"
  curl -fSL -o "$TARBALL" \
    "https://github.com/$REPO/releases/latest/download/session-pet-macos.tar.gz" || {
    echo "error: download failed — no release published yet?" >&2
    rm -f "$TARBALL"
    exit 1
  }
  tar -xzf "$TARBALL" -C "$ROOT" --strip-components 1
  rm -f "$TARBALL"
fi

if [ "${1:-}" = "--login-item" ]; then
  echo "▸ installing LaunchAgent (starts at login)"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.session-pet</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>/tmp/session-pet.out</string>
  <key>StandardErrorPath</key><string>/tmp/session-pet.err</string>
</dict>
</plist>
EOF
  pkill -x SessionPet 2>/dev/null || true
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "▸ pet started via launchd (and will start at every login)"
else
  pkill -x SessionPet 2>/dev/null || true
  nohup "$BIN" >/dev/null 2>&1 &
  echo "▸ pet started (this run only — use --login-item to survive reboots)"
fi

cat <<EOF

Optional — permission-prompt alerts (Claude Code): merge this fragment into
~/.claude/settings.json under "hooks" yourself (the installer never edits it):

  "Notification": [{"hooks": [{"type": "command", "async": true,
    "command": "jq -c . >> $ROOT/.state/events.jsonl"}]}]
EOF
if ! command -v jq >/dev/null 2>&1; then
  echo
  echo "  note: jq is not installed — the hook above needs it (brew install jq)."
fi
echo
echo "Done. Click the pet for its panel · drag to move · right-click to quit."
