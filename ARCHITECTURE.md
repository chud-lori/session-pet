# How session-pet works

One product, two native implementations, one shared state file.

```
native/          macOS — Swift/AppKit, scans and renders in one process
linux/core.py    Linux — Python (stdlib only): scans sessions, owns pet
                 state and XP, decides sounds. Port of the Swift scanner.
linux/face/      Linux — Rust + GTK3: draws the sprite, panel and sounds.
                 Spawns core.py and speaks NDJSON with it over stdin/stdout.
native/assets.json   sprite + species source of truth, read by BOTH faces
.state/state.json    XP, species, name, toggles — shared across platforms
```

Session transcripts are untrusted text, and on Linux only the Python core
parses them; the Rust face reads nothing but the core's own JSON.

## Detecting what a session is doing

Both implementations tail the same transcripts — Claude Code's
`~/.claude/projects/*.jsonl` and Codex's
`~/.codex/sessions/**/rollout-*.jsonl` — and normalize both providers into
one set of phases:

- **working** — mid-turn. Turn-end is read from the last assistant event
  (`stop_reason: end_turn` for Claude, `task_complete` for Codex), so a long
  tool run or a thinking pause never counts as "done".
- **ready** — the turn finished and nobody has looked yet. Unacknowledged
  after 3 minutes it fades to idle rather than nagging forever.
- **input** — an agent is literally asking you something
  (`AskUserQuestion`/`ExitPlanMode`, or Codex's `request_user_input`), or the
  optional Notification hook fired for a permission prompt.
- **stalled** — blocked mid-turn with no output for 5+ minutes: a permission
  prompt, a hung tool, a crash. Kept visible rather than vanishing.
- **idle** — quiet, or acknowledged.

Details that cost real debugging and are easy to regress:

- **An `end_turn` is not always the end of a turn.** Blocking Stop hooks and
  queued messages continue the conversation seconds later. The scanner waits
  out a short confirmation window and watches for hook-feedback events, so
  intermediate `end_turn`s never ding.
- **A new user prompt counts as working** even before the agent writes its
  first event — but only if it is recent, since an unanswered prompt from
  hours ago is an abandoned send, not an active turn.
- **Subagents** write under `<session-id>/subagents/**`. While they run the
  parent transcript is idle but the session is not, so their activity is
  folded into the parent.
- **Quiet sessions stay listed while their terminal is open**, which is
  detected from the process list rather than the transcript.

## Jump to terminal

Clicking a session card raises the terminal running it, without any hook or
shell integration. The agent process is found in the process list — matched
by its `--resume` id or its working directory — and its parent chain is
walked to the first GUI application, which is the hosting terminal or IDE.

How precisely it lands depends on what that app exposes:

| Terminal | Precision | Mechanism |
|---|---|---|
| iTerm2, Terminal.app (macOS) | **exact tab** | AppleScript match on the session's tty, so two tabs in one project are still told apart |
| Ghostty (macOS) | **exact tab/split** | Ghostty's scripting model exposes each surface's live working directory; paired with the tab title, which carries the session's own name |
| VS Code, JetBrains (macOS) | window | Accessibility: raise the window whose title contains the project |
| GNOME Terminal, Konsole, others (Linux/X11) | window | `_NET_WM_PID` on the ancestor chain, then window title — these serve every window from one process, so the title is what disambiguates |
| Wayland-native (Linux) | unavailable | no protocol exists for focusing another app's window |

Two traps worth remembering: AppleScript must target apps by **bundle id**
(iTerm2's scripting name is `iTerm`, so `tell application "iTerm2"` fails
outright and silently), and macOS grants Automation only to **bundled apps**,
which is why the installer ships an `.app` rather than a bare binary.

## Platform notes

**macOS** is a single Swift process: `Scanner.swift` reads transcripts,
`App.swift` runs the poll/animation tick, `PetView.swift` and `Panel.swift`
draw, `Jumper.swift` handles terminal focus. Per-pixel transparency comes
free from AppKit, so clicks land only on the pet's opaque pixels.

**Linux** splits core from face. X11 has no per-pixel hit testing, so the
face builds a GDK input-shape region from the sprite's opaque pixel runs to
get the same behavior. GTK3 is used rather than GTK4 deliberately: GTK4
removed `set_keep_above()` and window positioning, both load-bearing for a
floating desktop pet.

A GTK3 quirk worth knowing if you touch the pet window: button events are
dispatched **twice** (once for the window's own GdkWindow, once via child
propagation), so handlers dedupe on the event timestamp.

## Hacking

```bash
# macOS
swiftc -O native/src/*.swift -o native/SessionPet
./native/SessionPet [scale]          # default scale 5
./native/SessionPet --scan-once      # one JSON line per session, then exit
./native/SessionPet --jump <text>    # resolve a session and jump to it
./test/run.sh                        # phase-classification tests

# Linux
python3 linux/core.py --once         # one snapshot, pretty-printed
python3 linux/core.py --serve        # what the face runs
cd linux/face && cargo run -- 6      # face at scale 6 (needs a display)
```

`SESSION_PET_HOME` points the scanners at a fixture home instead of `$HOME`
(this is what the test harness uses). `SESSION_PET_ROOT` overrides where
state, sounds and sprites are read from. `SESSION_PET_LOG=1` writes
diagnostics to `/tmp/session-pet.log` and `/tmp/session-pet-core.log`.

Always compile-check Linux changes before shipping them — the face is built
from source on the user's machine, so a type error is a broken install.
