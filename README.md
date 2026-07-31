# <img src="docs/icon.svg" width="40" alt="session-pet dragon" align="top"> session-pet

A pixel-art desktop companion for your coding agents: one tiny always-on-top
native pet that watches **every Claude Code and Codex session** on your
machine. It bounces while agents work, dings the moment one needs your input,
flags sessions that stall mid-turn, shows live per-session cards, jumps you
back to the terminal running any session, and levels up across 10 species as
you ship.

Native on both platforms — Swift/AppKit on macOS, Rust/GTK on Linux — sharing
one pet, one XP pool, one `.state/state.json`. No Electron, no dependencies.

**Docs & tour:** <https://chud-lori.github.io/session-pet/>

## Install

```bash
# build deps — linux: sudo apt install libgtk-3-dev (+ cargo via rustup.rs)
#              macos: Xcode Command Line Tools (swiftc), macOS 13+
git clone https://github.com/chud-lori/session-pet.git
cd session-pet
./install.sh --login-item   # build + run + start at every login
```

No clone and no toolchain, once a release is published:

```bash
curl -fsSL https://raw.githubusercontent.com/chud-lori/session-pet/main/install.sh | sh
```

`./install.sh --uninstall` removes it on either OS. Full options, autostart,
Wayland notes and troubleshooting: **[INSTALL.md](INSTALL.md)**.

## Using the pet

| Action | How |
|---|---|
| Open the session panel | **click** the pet |
| Close the panel | click the pet again, or click anywhere outside |
| Move the pet | **drag** it |
| Menu (panel / sound / hide / quit) | **right-click** the pet |
| Watch a movie in peace | right-click → **Hide 30 min** — sounds keep working, and the pet returns early only if an agent needs your input |
| Jump to the terminal running a session (and acknowledge it) | **click** its card in the panel |
| Expand a session card (path, tokens, last message) | **right-click** the card |
| Change species / toggle sound / toggle wandering | panel → **settings ▸** |

The `pet` helper works from anywhere in the repo:

```bash
./pet          # start — or bring it back after quitting
./pet stop     # quit (same as right-click → Quit)
./pet status   # is it running?
```

**Sounds:** a quiet chime when a turn finishes; a louder **double ping** when
an agent needs you, repeating every 45s (max 3×) until you acknowledge it.
**Muted?** The pet also jumps excitedly and keeps a small reminder hop going
until you acknowledge it — motion catches the eye with the volume off.
**Dots under the pet** (2+ sessions): green = working, yellow = finished,
blinking red = needs you. **Wandering:** the pet takes short strolls along
your screen; wherever you drag it or it walks to becomes its new home.

## Optional — permission-prompt alerts

Claude Code permission prompts leave no trace in the transcript, so the pet
can't see them by reading files alone. This hook closes that gap; merge it
into `~/.claude/settings.json` under `"hooks"` (the installer never edits
your settings, and it needs `jq`):

```json
"Notification": [{"hooks": [{"type": "command", "async": true,
  "command": "jq -c . >> /path/to/session-pet/.state/events.jsonl"}]}]
```

Without it you still get alerts for `AskUserQuestion`/`ExitPlanMode` and
stall detection — you just lose the instant path for permission prompts.

## More docs

- **[INSTALL.md](INSTALL.md)** — every install flag, autostart, releases,
  Wayland/compositor notes, uninstalling
- **[CUSTOMIZING.md](CUSTOMIZING.md)** — sprite packs, sound packs,
  species/name CLI, the legacy statusline pet
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how sessions are detected, the
  macOS and Linux implementations, jump-to-terminal precision, hacking
  and tests

## Non-goals

Kept deliberately out of scope — say no early, stay small:

- **No 17-provider support** — Claude Code + Codex only.
- **No in-pet approve/deny** of permission prompts; the pet notifies, you act
  in the terminal.
- **No chat-with-agent** from the pet window.
- **No menu-bar / notch rewrite** — it stays a floating desktop pet.
- **No more gamification** — XP, stages, and species are the ceiling.

**False-positive budget:** any false *needs-input* or *ready* ding is
release-blocking; a false *working* is tolerable but must be time-bounded.

