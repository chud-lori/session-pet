# Installing session-pet

One installer covers macOS and Linux. It detects the OS, builds from source
inside a clone, and downloads a prebuilt binary when there is no source tree.

## From a clone (builds from source)

```bash
git clone https://github.com/chud-lori/session-pet.git
cd session-pet
./install.sh                # build + run now
./install.sh --login-item   # …and start at every login
./install.sh --uninstall    # stop it, remove the login entry
```

Build requirements:

| Platform | Needs |
|---|---|
| macOS 13+ | Xcode Command Line Tools (`swiftc`), `python3` |
| Linux | `cargo` ([rustup.rs](https://rustup.rs)), `libgtk-3-dev`, `python3` |

On Ubuntu/Debian: `sudo apt install libgtk-3-dev`. The installer checks for
the GTK headers and tells you what to run — it never invokes `sudo` itself.

## Without a clone (prebuilt)

```bash
curl -fsSL https://raw.githubusercontent.com/chud-lori/session-pet/main/install.sh | sh
```

Pass flags through the pipe with `sh -s --`, e.g.
`… | sh -s -- --login-item`. This path needs a published release; until one
is tagged it exits with a message and you should build from a clone instead.

Prebuilt runtime requirements are much smaller — `python3` plus, on Linux,
the GTK3 runtime every GNOME/KDE/XFCE desktop already ships. The Linux
binary embeds the Python core and sprite assets, so it runs standalone and
keeps its state in `~/.local/share/session-pet`.

Installing from a clone instead keeps state in the clone, and pins that path
in `~/.config/session-pet/root` so the autostart entry, a desktop launcher
and a terminal run all open the *same* pet. Re-run the installer after moving
a clone; `SESSION_PET_ROOT=/path` overrides the pin for one run.

### Linux-only flags

| Flag | Effect |
|---|---|
| `--download` | force the prebuilt path even inside a clone |
| `--from-source` | force a source build |
| `--layer-shell` | source build with Wayland layer-shell support (see below) |
| `--version vX.Y.Z` | install a specific release instead of the latest |
| `--autostart` | XDG autostart entry (`--login-item` maps to this) |

## Starting at login

- **macOS** — a LaunchAgent at `~/Library/LaunchAgents/com.session-pet.plist`,
  with `KeepAlive` so the pet returns if it ever dies.
- **Linux** — an XDG autostart entry at
  `~/.config/autostart/session-pet.desktop`.

Both are installed by `--login-item`/`--autostart` and removed by
`--uninstall`, which leaves your pet's XP and species untouched.

## macOS: the app bundle and permissions

The installer wraps the binary in `native/SessionPet.app`. This is not
cosmetic: macOS only grants **Automation** permission to apps with a bundle
identifier, and jump-to-terminal needs it to focus a terminal tab. A bare
executable is denied silently.

The first time you click a session card, macOS asks for permission to
control your terminal. Approve it once. If you decline, the pet still brings
the app to the front — it just can't select the exact tab. Change your mind
later in **System Settings → Privacy & Security → Automation**.

## Linux: Wayland and compositors

The pet needs always-on-top and self-positioning, which Wayland deliberately
denies to ordinary clients. The face therefore pins the X11 backend
(`GDK_BACKEND=x11`) unless you override it, so it runs under XWayland — the
default on Ubuntu GNOME and fine everywhere.

- **X11 / XWayland (incl. Ubuntu GNOME)** — everything works.
- **Pure Wayland on KDE, sway, Hyprland** — build with
  `./install.sh --from-source --layer-shell` and the pet becomes a real
  overlay surface. Position is fixed and dragging is disabled there, because
  compositors don't let clients move layer surfaces.
- **Pure Wayland on GNOME** — no layer-shell support exists; stay on
  XWayland (nothing to do, it's the default).

Jump-to-terminal is X11/XWayland-only for the same reason: Wayland has no
protocol for focusing another application's window.

## Releases

Tagging `v*` builds `session-pet-linux-{x86_64,arm64}` and a universal
`session-pet-macos.tar.gz` via `.github/workflows/release.yml`. Linux release
binaries are built **without** layer-shell on purpose, so their only
dependencies stay `python3` and the GTK3 runtime.

## Reinstalling and troubleshooting

```bash
git pull && ./install.sh    # rebuild + restart; no need to uninstall first
```

The installer kills the running pet before starting the new one, so a plain
reinstall always picks up your changes. If the pet seems to ignore new
behavior, it is almost always still running an older binary — check with
`./pet status` and restart it.

For a clean slate:

```bash
./install.sh --uninstall
rm -rf ~/.local/share/session-pet   # Linux standalone state (wipes XP)
rm -f ~/.config/session-pet/root    # Linux: forget the pinned state root
./install.sh
```

Logging: run with `SESSION_PET_LOG=1` to write diagnostics to
`/tmp/session-pet.log` (macOS) or `/tmp/session-pet-core.log` (Linux core).
