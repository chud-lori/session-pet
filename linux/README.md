# session-pet on Linux

Same pet, same XP, same sessions — different native face. The Mac app stays
pure Swift/AppKit (`native/`); Linux gets a **core/face split**:

```
linux/core.py    Python (stdlib only) — scans ~/.claude + ~/.codex transcripts,
                 owns pet state/XP, decides sounds. Port of the Swift Scanner.
linux/face/      Rust + GTK3 — draws the sprite, plays sounds, panel, clicks.
                 Spawns core.py and speaks NDJSON with it over stdin/stdout.
```

All parsing of session transcripts (untrusted text) happens in the Python
core; the Rust face only reads the core's own JSON. Sprites come from the
same `native/assets.json` the Mac app uses, and `.state/state.json` is shared
— your dragon keeps its level across OSes.

## Install

One-liner (no clone — downloads a prebuilt binary, extracts the embedded
core to `~/.local/share/session-pet`):

```sh
curl -fsSL https://raw.githubusercontent.com/chud-lori/session-pet/main/linux/install.sh | sh
```

From a clone (auto-builds from source when cargo is available):

```sh
git clone https://github.com/chud-lori/session-pet.git
cd session-pet
./install.sh --login-item    # same entry point as the Mac — delegates here
```

Flags: `--autostart` (start at login), `--download`, `--from-source`,
`--layer-shell`, `--version vX.Y.Z`, `--uninstall`.

**Requirements:** `python3` and the GTK3 runtime (already present on GNOME/
KDE/XFCE desktops). Source builds need `cargo` + `libgtk-3-dev`. Sound uses
`paplay`, `pw-play`, or `ffplay` — first one found; none is fine, just silent.

## Wayland notes (read me if the pet won't stay on top)

- **X11 / XWayland** (incl. Ubuntu GNOME): works out of the box — the pet is
  a borderless always-on-top window, drag anywhere.
- **Pure Wayland on KDE / sway / Hyprland:** build from source with
  `./linux/install.sh --from-source --layer-shell` — the pet becomes a real
  overlay (layer-shell). Position is fixed bottom-right; dragging is disabled
  there (compositors don't let clients move layer surfaces).
- **Pure Wayland on GNOME:** GNOME does not support layer-shell, and Wayland
  forbids apps from setting always-on-top themselves. Run the pet under
  XWayland instead: `GDK_BACKEND=x11 session-pet-linux` (the default install
  works because GTK3 apps fall back to XWayland automatically).

## Releases

Tags `v*` build `session-pet-linux-{x86_64,arm64}` via
`.github/workflows/release-linux.yml`. Release binaries are built **without**
layer-shell so their only deps are python3 + GTK3 runtime (tangi convention:
prebuilts carry no optional shared-lib deps).

## Hacking

```sh
python3 linux/core.py --once          # one snapshot, pretty-printed
python3 linux/core.py --serve         # what the face runs
cd linux/face && cargo run -- 6       # face at scale 6 (needs a display)
```

The face finds a repo clone by walking up from its own binary; otherwise it
runs standalone from `~/.local/share/session-pet`. `SESSION_PET_ROOT`
overrides the state/sounds/sprites root either way; `SESSION_PET_HOME`
points the scanners at a fixture home (same as the Mac app's test rig).
