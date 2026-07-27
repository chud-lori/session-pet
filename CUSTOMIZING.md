# Customizing session-pet

Everything here is shared by both platforms: the same sprite packs, the same
sound packs, the same `.state/state.json`.

## Sprite packs

Drop a JSON file into `sprites/` — one species per file, picked up at the
next launch and added to the species picker. No rebuild, no export step.

- **Species key = filename stem.** `sprites/example-slime.json` becomes
  species `example-slime`. If the key matches a built-in (`cat`, `egg`, …),
  **your pack wins** and replaces that sprite.
- **Schema** — the same shape as one `species` entry in
  `native/assets.json`:

  ```json
  {"name": "Slimey", "emoji": "🫧",
   "palette": {"X": "#7ee8a2", "k": "#2f4a33"},
   "rows": ["....kkkk....", "...kXXXXk..."]}
  ```

  Rows are pixel strings; each character is a palette key.
- **Walk cycle (optional)** — add a `"walk"` key holding an array of frames,
  each the same shape as `"rows"`, and the pet uses them while strolling.
  Packs without it get an automatic two-frame leg shuffle.
- **Conventions** — `.` is transparent; `o`/`w` are eye pixels (the pet
  redraws them as `X` while blinking, so use `X` as the main body color to
  make closed eyes look right). Built-ins are 16px wide.
- Malformed files (bad JSON, missing or empty `rows`) are skipped, never
  fatal. Run with `SESSION_PET_LOG=1` to see what got skipped.
- `sprites/example-slime.json` ships as a working template.

Built-in sprites live in `native/assets.json`, which is the **source of
truth** for both platforms. It is generated from the legacy Python pixel
maps by `python3 native/export_assets.py` — re-run that after editing them.

## Sound packs

The two pet sounds are overridable via optional keys in
`.state/state.json`:

- `"soundReady"` — a turn finished
- `"soundInput"` — an agent needs you
- `"soundVolume"` — gain, default 1.6 for input and 1.0 for ready

Values are either an absolute path or a bare filename resolved against the
repo's `sounds/` directory, so `{"soundReady": "meow.wav"}` plays
`sounds/meow.wav`. A missing or unplayable file falls back to the platform
default silently.

Defaults differ per platform because the mechanisms do: macOS plays system
`.aiff` sounds through `afplay`, Linux plays the freedesktop `.oga` theme
through `paplay`, `pw-play` or `ffplay` (first one found; none installed
just means silence). **For a portable pack, use `.wav` or `.mp3`** — `.aiff`
is unreliable on Linux players and `.oga` can't be played by `afplay`.

## Species and name

Change them from the panel (**settings ▸**) or, on macOS, from the legacy
statusline pet's CLI:

```bash
python3 pet.py species              # list species (← marks current)
python3 pet.py set species dragon   # pick your pet
python3 pet.py set name Smaug       # rename it
python3 pet.py status               # XP / stage outside the statusline
```

The name shows as `???` until the egg hatches (30 XP, or instantly when you
pick a sprite).

## The statusline pet (legacy)

`pet.py` renders a tiny pet inside the Claude Code statusline. It shares
XP, species and name with the desktop pet through `.state/state.json`.

```json
"statusLine": {
  "type": "command",
  "command": "python3 /path/to/session-pet/pet.py"
}
```

Claude Code invokes it on conversation updates (throttled to ~300 ms) and
pipes session JSON to stdin. It derives state from the transcript's mtime
(<15 s = working, <5 min = waiting, else sleeping), animates from the wall
clock, and earns XP from each session's `lines_added + lines_removed + cost`
summed across every session ever — old sessions get pruned into `banked_xp`,
so nothing is lost. It is stdlib-only and always exits 0, because a
statusline must never break the harness.

`pet_window.py` — the original Tkinter desktop pet — is **deprecated** and
kept for reference only. The native apps replaced it on both platforms.
