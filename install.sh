#!/usr/bin/env bash
# session-pet installer — build the native pet and (optionally) start it at login.
#
#   ./install.sh                 build + run now
#   ./install.sh --login-item    build + install a LaunchAgent (starts at every
#                                login, incl. after reboot) + run now
#   ./install.sh --uninstall     remove the LaunchAgent and stop the pet
#
# Requirements: macOS 13+, Xcode Command Line Tools (swiftc), python3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.session-pet.plist"
BIN="$ROOT/native/SessionPet"
mkdir -p "$ROOT/.state"   # fresh clones ship without it; the pet/hook need it

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  pkill -x SessionPet 2>/dev/null || true
  echo "session-pet uninstalled (repo and pet state left untouched)"
  exit 0
fi

echo "▸ exporting sprite assets"
python3 "$ROOT/native/export_assets.py"

echo "▸ building native pet"
swiftc -O "$ROOT/native/SessionPet.swift" -o "$BIN"

if [[ "${1:-}" == "--login-item" ]]; then
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
  disown
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
