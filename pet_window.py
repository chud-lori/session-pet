#!/usr/bin/env python3
"""session-pet — a desktop pixel-art pet for your coding agents.

One frameless always-on-top chibi pet that mirrors what ALL your agent
sessions are doing — Claude Code (~/.claude/projects/*.jsonl) and Codex
(~/.codex/sessions/**/rollout-*.jsonl):

  · bounces + sparkles while Claude works
  · "!" bubble + a sound when Claude finishes / needs your input
  · drifting z's when everything is idle

Click the pet to open its details modal — progress to the next stage, live
Claude status, active project, sound toggle, and a visual sprite picker — just
like the Codex desktop pet's click-for-details panel. Species, name, and XP are
shared with the statusline pet (pet.py) via .state/state.json.

Run:        python3 pet_window.py [--scale N]
Controls:   drag to move · click for the modal · right-click to quit

Stdlib only (tkinter + afplay for sound). Companion to pet.py; see README.md.
"""
import glob
import json
import os
import subprocess
import sys
import time
import tkinter as tk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pet  # SPECIES, load_state, save_state, total_xp, stage_for

SCALE = 4  # 16px sprites: scale 4 ≈ the original compact window size
BG = "#1e1e28"
CARD = "#181825"
FG = "#cdd6f4"
MUTED = "#7f849c"
ACCENT = "#a6e3a1"
WARN = "#ffd166"

SOUND_READY = "/System/Library/Sounds/Glass.aiff"   # Claude finished → your turn
SOUND_INPUT = "/System/Library/Sounds/Ping.aiff"    # Claude is asking you something
SOUND_DEBOUNCE = 8  # seconds between sounds
INPUT_TOOLS = ("AskUserQuestion", "ExitPlanMode")   # tool calls that block on the user

# ---------------------------------------------------------------- sprites ----
# 16px-wide chibi pixel maps. Chars: '.' empty · 'k' outline · 'X' base ·
# 'd' shade · 'o' eye · 'w' eye sparkle (o/w close on blink/sleep) · rest per-palette.
PIXELS = {
    "egg": {"palette": {"X": "#f6ecd8", "d": "#dcc9a4", "l": "#fffaf0", "k": "#3a3644"}, "rows": [
        "......kkkk......",
        "....kkXXXXkk....",
        "...kXXlXXXXXk...",
        "..kXllXXXXXXXk..",
        ".kXlXXXXXXdXXXk.",
        ".kXXXXXXXXXXXXk.",
        "kXXXXdXXXXXXXXXk",
        "kXXXXXXXXXdXXXXk",
        ".kXXXXXXXXXXXXk.",
        ".kdXXXXXXXXXXdk.",
        "..kdXXXXXXXXdk..",
        "....kkddddkk....",
    ]},
    "cat": {"palette": {"X": "#aab1bc", "d": "#8b91a0", "o": "#26262e", "w": "#ffffff",
                        "p": "#f0a5bb", "k": "#3a3644"}, "rows": [
        "..kk........kk..",
        ".kXXk......kXXk.",
        ".kXpXk....kXpXk.",
        ".kXXXXkkkkXXXXk.",
        ".kXXXXXXXXXXXXk.",
        "kXXXXXXXXXXXXXXk",
        "kXXooXXXXXXooXXk",
        "kXXowXXXXXXowXXk",
        "kXXXXXXkppkXXXXk",
        "kdXXXXXXXXXXXXdk",
        ".kXXXXXXXXXXXXk.",
        "..kXXXXXXXXXXk..",
        "..kXXXXXXXXXXk..",
        "..kdXXk..kXXdk..",
        "...kk......kk...",
    ]},
    "dragon": {"palette": {"X": "#6fce73", "d": "#57b25c", "o": "#26262e", "w": "#ffffff",
                           "h": "#ffd166", "b": "#d9f2c9", "k": "#2f4a33"}, "rows": [
        "..hh........hh..",
        ".khhk......khhk.",
        ".kXXk......kXXk.",
        ".kXXXXkkkkXXXXk.",
        ".kXXXXXXXXXXXXk.",
        "kXXXXXXXXXXXXXXk",
        "kXXooXXXXXXooXXk",
        "kXXowXXXXXXowXXk",
        "kXXXXXkddkXXXXXk",
        "kdXXXXXXXXXXXXdk",
        ".kXXXbbbbbbXXXk.",
        "..kXXbbbbbbXXk..",
        "..kXXbbbbbbXXk..",
        "..kdXXk..kXXdk..",
        "...kk......kk...",
    ]},
    "crab": {"palette": {"X": "#f26d6d", "d": "#d15757", "o": "#26262e", "w": "#ffffff",
                         "k": "#4a2f33"}, "rows": [
        ".kk..........kk.",
        "kXXk........kXXk",
        "kXXk.kkkkkk.kXXk",
        ".kkkXXXXXXXXkkk.",
        "..kXXXXXXXXXXk..",
        ".kXXooXXXXooXXk.",
        ".kXXowXXXXowXXk.",
        ".kXXXXkkkkXXXXk.",
        "..kXXXXXXXXXXk..",
        "...kXk.kk.kXk...",
    ]},
    "octopus": {"palette": {"X": "#b678d4", "d": "#9a5cbb", "o": "#26262e", "w": "#ffffff",
                            "k": "#3f3050"}, "rows": [
        "....kkkkkkkk....",
        "..kkXXXXXXXXkk..",
        ".kXXXXXXXXXXXXk.",
        "kXXXXXXXXXXXXXXk",
        "kXooXXXXXXXXooXk",
        "kXowXXXXXXXXowXk",
        "kXXXXXkkkkXXXXXk",
        ".kXXXXXXXXXXXXk.",
        ".kXkXXkXXkXXkXk.",
        ".kk.kk.kk.kk.kk.",
    ]},
    "dino": {"palette": {"X": "#4fbfae", "d": "#3da393", "o": "#26262e", "w": "#ffffff",
                         "W": "#e8f7e0", "s": "#2f8f80", "k": "#2e4a45"}, "rows": [
        ".....ss..ss.....",
        "....kXXkkXXk....",
        "...kXXXXXXXXk...",
        "..kXXXXXXXXXXk..",
        ".kXXXXXXXXXXXXk.",
        "kXXooXXXXXXooXXk",
        "kXXowXXXXXXowXXk",
        "kXXXXXkkkkXXXXXk",
        ".kXXXXXXXXXXXXk.",
        "..kXXWWWWWWXXk..",
        "..kXXWWWWWWXXk..",
        "..kXXWWWWWWXXkk.",
        "..kdXXk..kXXdkXk",
        "...kk......kk...",
    ]},
    "fox": {"palette": {"X": "#f28c4b", "d": "#d97636", "o": "#26262e", "w": "#ffffff",
                        "W": "#fdf3e3", "p": "#e8828f", "k": "#4a3326"}, "rows": [
        "..kk........kk..",
        ".kXXk......kXXk.",
        ".kXWXk....kXWXk.",
        ".kXXXXkkkkXXXXk.",
        ".kXXXXXXXXXXXXk.",
        "kXXXXXXXXXXXXXXk",
        "kXXooXXXXXXooXXk",
        "kXXowXXXXXXowXXk",
        "kWWXXXXkppkXXWWk",
        "kdWXXXXXXXXXXWdk",
        ".kXXXXXXXXXXXXk.",
        "..kXXWWWWWWXXk..",
        "..kXXWWWWWWXXk..",
        "..kdXXk..kXXdk..",
        "...kk......kk...",
    ]},
    "alien": {"palette": {"X": "#9ee493", "d": "#7fca77", "o": "#26262e", "w": "#ffffff",
                          "h": "#ffd166", "k": "#33453a"}, "rows": [
        ".khk........khk.",
        "...k........k...",
        "..kkXXXXXXXXkk..",
        ".kXXXXXXXXXXXXk.",
        "kXXXXXXXXXXXXXXk",
        "kXoooXXXXXXoooXk",
        "kXooowXXXXooowXk",
        ".kXXXXXXXXXXXXk.",
        ".kXXXXkkkkXXXXk.",
        "..kXXXXXXXXXXk..",
        "...kXXXXXXXXk...",
        "...kXXk..kXXk...",
        "....kk....kk....",
    ]},
    "turtle": {"palette": {"X": "#8fd18a", "d": "#72b56e", "o": "#26262e", "w": "#ffffff",
                           "S": "#b08968", "D": "#8f6b4d", "k": "#3d4a33"}, "rows": [
        "....kkkkkkkk....",
        "...kXXXXXXXXk...",
        "..kXXXXXXXXXXk..",
        "..kXooXXXXooXk..",
        "..kXowXXXXowXk..",
        "..kXXXkkkkXXXk..",
        ".kSSSSSSSSSSSSk.",
        "kSSDSSDSSDSSDSSk",
        "kSSSSSSSSSSSSSSk",
        ".kSDSSDSSDSSDSk.",
        "..kkkkkkkkkkkk..",
        "..kXXk....kXXk..",
        "...kk......kk...",
    ]},
}

SPRITE_COLS = 16          # all maps are 16px wide
CANVAS_COLS = 18          # canvas width in sprite pixels (room for effects)
CANVAS_ROWS = 22          # sprite (15) + bob/effects headroom + dots + caption

# hook-event spool (code-island style push events — catches permission prompts
# that transcripts never record; see README for the one-line hook to install)
EVENTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           ".state", "events.jsonl")

WORKING_WITHIN, WAITING_WITHIN = pet.WORKING_WITHIN, pet.WAITING_WITHIN
STAGE_NEXT = {"egg": "hatchling", "hatchling": "adult", "adult": "legendary"}

# Session sources — one pet watches every coding agent on this machine
# (normalization idea borrowed from code-island's multi-provider bridge).
CLAUDE_GLOB = os.path.expanduser("~/.claude/projects/*/*.jsonl")
CODEX_GLOB = os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl")


def paint_pixels(canvas, key, scale, ox, oy, eyes_closed=False):
    """Draw a pixel map onto any canvas (pet window or modal picker)."""
    spec = PIXELS.get(key, PIXELS["cat"])
    for y, row in enumerate(spec["rows"]):
        for x, ch in enumerate(row):
            if ch == ".":
                continue
            if eyes_closed and ch in ("o", "w"):
                ch = "X"
            color = spec["palette"].get(ch, "#ffffff")
            canvas.create_rectangle(ox + x * scale, oy + y * scale,
                                    ox + (x + 1) * scale, oy + (y + 1) * scale,
                                    fill=color, outline="")


RECENT_WINDOW = 3600      # ignore transcripts idle longer than this
BUSY_GRACE = 300          # last event = tool call/result → still busy up to 5 min


def tail_info(path):
    """What the last assistant event in a transcript says: {stop, tool, detail}.

    mtime alone lies: Claude can go a long while without writing (long tool run,
    thinking). A turn is only truly over when the final assistant message
    carries stop_reason end_turn / stop_sequence; a trailing tool_use block
    tells us WHAT it is doing — and if that tool is AskUserQuestion/ExitPlanMode,
    Claude is blocked on the user right now.
    """
    info = {"stop": None, "tool": None, "detail": ""}
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 65536))
            lines = f.read().decode("utf-8", "replace").strip().splitlines()
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                info["stop"] = "writing"  # partial line: mid-write right now
                return info
            if ev.get("type") == "assistant":
                msg = ev.get("message") or {}
                info["stop"] = msg.get("stop_reason")
                for block in reversed(msg.get("content") or []):
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        info["tool"] = block.get("name")
                        inp = block.get("input") or {}
                        detail = (inp.get("description") or inp.get("command")
                                  or inp.get("file_path") or inp.get("pattern") or "")
                        info["detail"] = str(detail).split("\n")[0][:44]
                        break
                return info
            if ev.get("type") in ("user", "progress"):
                info["stop"] = "pending"  # tool result landed — Claude's turn next
                return info
        return info
    except Exception:
        return info


def fmt_age(age):
    if age < 60:
        return "%ds" % age
    if age < 3600:
        return "%dm" % (age // 60)
    return "%dh" % (age // 3600)


def project_label(path):
    """Human-ish project name from a Claude Code transcript path."""
    label = os.path.basename(os.path.dirname(path))
    home_key = "-" + os.path.expanduser("~").strip("/").replace("/", "-") + "-"
    if label.startswith(home_key):
        label = "~/" + label[len(home_key):]
    return label


def codex_label(path):
    """Project label for a Codex rollout: cwd from the session_meta first line."""
    cached = codex_label._cache.get(path)
    if cached:
        return cached
    label = "codex"
    try:
        with open(path) as f:
            first = json.loads(f.readline())
        cwd = (first.get("payload") or {}).get("cwd") or ""
        home = os.path.expanduser("~")
        if cwd.startswith(home):
            cwd = "~" + cwd[len(home):]
        label = cwd or "codex"
    except Exception:
        pass
    codex_label._cache[path] = label
    return label


codex_label._cache = {}


def session_label(path, provider):
    return codex_label(path) if provider == "codex" else project_label(path)


def tail_info_codex(path):
    """Codex rollout equivalent of tail_info, normalized to the same shape:
    task_complete → end_turn · request_user_input → an input-blocking tool ·
    function/shell calls → tool_use with what it is running."""
    info = {"stop": None, "tool": None, "detail": ""}
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 65536))
            lines = f.read().decode("utf-8", "replace").strip().splitlines()
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                info["stop"] = "writing"
                return info
            p = ev.get("payload") or {}
            pt = p.get("type")
            if ev.get("type") == "event_msg":
                if pt == "task_complete":
                    info["stop"] = "end_turn"
                    return info
                if pt in ("request_user_input", "elicitation_request"):
                    info.update(stop="tool_use", tool="AskUserQuestion",
                                detail="question for you")
                    return info
                if pt == "exec_command_begin":
                    info.update(stop="tool_use", tool="shell",
                                detail=str(p.get("command") or "")[:44])
                    return info
                if pt == "task_started":
                    info["stop"] = "pending"
                    return info
                continue  # token_count / deltas / other chatter
            if ev.get("type") == "response_item":
                if pt == "function_call":
                    info.update(stop="tool_use", tool=p.get("name") or "tool",
                                detail=str(p.get("arguments") or "")[:44])
                    return info
                if pt == "local_shell_call":
                    cmd = (p.get("action") or {}).get("command") or ""
                    info.update(stop="tool_use", tool="shell", detail=str(cmd)[:44])
                    return info
                if pt == "message":
                    info["stop"] = "pending"  # mid-task message; end is task_complete
                    return info
                continue
        return info
    except Exception:
        return info


SOURCES = (("claude", CLAUDE_GLOB, tail_info), ("codex", CODEX_GLOB, tail_info_codex))


def scan_sessions():
    """Classify every recently-active session.

    Returns a list of (path, age, phase), phase ∈ working | busy | ready,
    sorted most-recent first.
    """
    now = time.time()
    _cache = scan_sessions._cache
    sessions = []
    for provider, pattern, tailer in SOURCES:
      for path in glob.glob(pattern):
        try:
            age = now - os.path.getmtime(path)
        except OSError:
            continue
        if age > RECENT_WINDOW:
            continue
        mtime = now - age
        cached = _cache.get(path)
        info = cached[1] if cached and cached[0] == mtime else tailer(path)
        _cache[path] = (mtime, info)

        doing = ""
        if info["stop"] == "tool_use" and info["tool"] in INPUT_TOOLS and age > 3:
            phase = "input"            # Claude is literally asking the user something
            doing = "needs your answer!"
        elif age < WORKING_WITHIN:
            phase = "working"          # actively writing the transcript
            if info["stop"] == "tool_use" and info["tool"]:
                doing = "%s · %s" % (info["tool"], info["detail"]) if info["detail"] else info["tool"]
            else:
                doing = "thinking / writing"
        elif info["stop"] in ("end_turn", "stop_sequence"):
            if age < WAITING_WITHIN:
                phase = "ready"        # freshly finished — worth your attention
                doing = "just finished — waiting for you"
            else:
                phase = "idle"         # long done: shown for context, no nagging
                doing = "done %s ago" % fmt_age(age)
        elif age < BUSY_GRACE:
            phase = "busy"             # mid-turn: long tool run / approval prompt
            if info["tool"]:
                doing = "%s (%.0fs) · %s" % (info["tool"], age, info["detail"])
            else:
                doing = "busy (%.0fs)" % age
        else:
            continue                   # stale mid-turn session — ignore
        sessions.append((path, age, phase, doing, provider))
    return sorted(sessions, key=lambda s: s[1])


scan_sessions._cache = {}  # path → (mtime, stop_reason): skip re-reading idle tails


def play_sound(sound=SOUND_READY):
    try:
        subprocess.Popen(["afplay", sound],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


class PetWindow:
    def __init__(self, scale=SCALE):
        self.scale = scale
        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        # true transparency (macOS aqua Tk): only the sprite pixels show, no box
        try:
            self.root.config(bg="systemTransparent")
            self.root.attributes("-transparent", True)
            win_bg = "systemTransparent"
        except tk.TclError:
            win_bg = BG  # fallback: solid card look
        self.canvas = tk.Canvas(self.root, width=CANVAS_COLS * scale,
                                height=CANVAS_ROWS * scale, bg=win_bg,
                                highlightthickness=0)
        self.canvas.pack()
        # the name caption is drawn on the canvas (with an outline) rather than
        # a Label: outlined text stays readable over white windows too

        # bottom-right corner, above the Dock
        self.root.update_idletasks()
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        self.root.geometry("+%d+%d" % (sw - CANVAS_COLS * scale - 40,
                                       sh - CANVAS_ROWS * scale - 130))

        for w in (self.canvas,):
            w.bind("<ButtonPress-1>", self.press)
            w.bind("<B1-Motion>", self.drag_move)
            w.bind("<ButtonRelease-1>", self.release)
            w.bind("<Button-2>", lambda e: self.root.destroy())
            w.bind("<Button-3>", lambda e: self.root.destroy())

        self.frame = 0
        self.mode = "waiting"
        self.sessions = []
        self.state = pet.load_state()
        self.sess_prev = {}
        self.n_active = self.n_ready = self.n_input = 0
        self.last_poll = 0.0
        self.last_sound = 0.0
        self.alert_until = 0.0
        self.modal = None
        self.ev_off = 0    # read offset into the hook-event spool
        self.notif = {}    # transcript_path → (event time, message)
        self.tick()

    # -- hook events (permission prompts never reach the transcript) --------
    def read_events(self):
        try:
            size = os.path.getsize(EVENTS_FILE)
        except OSError:
            return  # spool absent: hooks not installed, polling still works
        if size < self.ev_off:
            self.ev_off = 0  # spool was truncated/rotated
        if size == self.ev_off:
            return
        try:
            with open(EVENTS_FILE) as f:
                f.seek(self.ev_off)
                chunk = f.read()
                self.ev_off = f.tell()
        except OSError:
            return
        for line in chunk.splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("hook_event_name") == "Notification":
                path = ev.get("transcript_path") or ""
                msg = ev.get("message") or "needs your attention"
                self.notif[path] = (time.time(), msg)

    # -- interactions ------------------------------------------------------
    def press(self, e):
        self._px, self._py = e.x_root, e.y_root
        self._wx, self._wy = self.root.winfo_x(), self.root.winfo_y()
        self._dragged = False

    def drag_move(self, e):
        # generous threshold: trackpad clicks wobble a few px and must still count
        # as clicks (open the modal), not drags
        if abs(e.x_root - self._px) + abs(e.y_root - self._py) > 10:
            self._dragged = True
        self.root.geometry("+%d+%d" % (self._wx + e.x_root - self._px,
                                       self._wy + e.y_root - self._py))
        if self.modal:
            self.place_modal()

    def release(self, _e):
        if self._dragged:
            return
        self.toggle_modal()  # click: show · click again: hide

    def choose_species(self, key):
        state = pet.load_state()
        state["species"] = key
        state["hatched"] = True  # an explicit pick hatches the egg immediately
        state.pop("name", None)  # revert to the new species' default name
        pet.save_state(state)
        self.state = state
        self.update_modal()

    def toggle_picker(self):
        self.picker_open = not self.picker_open
        if self.picker_open:
            self.picker_frame.pack(padx=12, pady=(4, 0), anchor="w",
                                   after=self.picker_btn)
            self.picker_btn.config(text="settings ▾")
        else:
            self.picker_frame.pack_forget()
            self.picker_btn.config(text="settings ▸")
        self.place_modal()  # the modal just changed size — keep it on screen

    def toggle_sound(self):
        state = pet.load_state()
        state["sound"] = bool(self.sound_var.get())
        pet.save_state(state)
        self.state = state

    # -- modal (codex-desktop-pet style details panel) ---------------------
    def toggle_modal(self):
        if self.modal:
            self.modal.destroy()
            self.modal = None
            return
        m = tk.Toplevel(self.root)
        m.overrideredirect(True)
        m.attributes("-topmost", True)
        m.configure(bg=CARD)
        pad = {"padx": 14, "anchor": "w"}

        self.m_title = tk.Label(m, bg=CARD, fg=FG, font=("Menlo", 13, "bold"))
        self.m_title.pack(pady=(12, 2), **pad)
        self.m_stage = tk.Label(m, bg=CARD, fg=MUTED, font=("Menlo", 10))
        self.m_stage.pack(**pad)

        self.m_bar = tk.Canvas(m, width=200, height=10, bg="#313244",
                               highlightthickness=0)
        self.m_bar.pack(pady=(6, 2), padx=14, anchor="w")
        self.m_xp = tk.Label(m, bg=CARD, fg=MUTED, font=("Menlo", 9))
        self.m_xp.pack(**pad)

        tk.Frame(m, bg="#313244", height=1).pack(fill="x", padx=10, pady=8)
        self.m_status = tk.Label(m, bg=CARD, fg=FG, font=("Menlo", 10))
        self.m_status.pack(**pad)
        self.m_sessions = tk.Frame(m, bg=CARD)  # one row per live session
        self.m_sessions.pack(fill="x", **pad)

        # settings — everything non-info lives behind one collapsed expander
        tk.Frame(m, bg="#313244", height=1).pack(fill="x", padx=10, pady=8)
        self.picker_open = False
        self.picker_btn = tk.Label(m, text="settings ▸", bg=CARD, fg=FG,
                                   cursor="hand2", font=("Menlo", 9, "underline"))
        self.picker_btn.pack(**pad)
        self.picker_btn.bind("<Button-1>", lambda _e: self.toggle_picker())

        self.picker_frame = tk.Frame(m, bg=CARD)  # packed only while open
        tk.Label(self.picker_frame, text="choose your pet", bg=CARD, fg=MUTED,
                 font=("Menlo", 9)).pack(anchor="w")
        grid = tk.Frame(self.picker_frame, bg=CARD)
        grid.pack(anchor="w", pady=(2, 0))
        self.pick = {}
        mini = 2  # picker sprite scale
        for i, key in enumerate(pet.SPECIES):
            rows = PIXELS[key]["rows"]
            c = tk.Canvas(grid, width=SPRITE_COLS * mini + 6,
                          height=15 * mini + 6, bg=CARD, highlightthickness=2)
            oy = (15 - len(rows)) * mini // 2 + 3
            paint_pixels(c, key, mini, 3, oy)
            c.grid(row=i // 4, column=i % 4, padx=3, pady=3)
            c.bind("<Button-1>", lambda _e, k=key: self.choose_species(k))
            self.pick[key] = c

        self.sound_var = tk.BooleanVar(value=self.state.get("sound", True))
        tk.Checkbutton(self.picker_frame, text="sound when an agent needs me",
                       variable=self.sound_var, command=self.toggle_sound,
                       bg=CARD, fg=FG, font=("Menlo", 9), selectcolor=CARD,
                       activebackground=CARD,
                       activeforeground=FG).pack(pady=(6, 0), anchor="w")

        row = tk.Frame(m, bg=CARD)
        row.pack(pady=(8, 12), padx=14, anchor="w")
        for text, cmd in (("close", self.toggle_modal), ("quit", self.root.destroy)):
            tk.Button(row, text=text, command=cmd, font=("Menlo", 9),
                      highlightbackground=CARD).pack(side="left", padx=(0, 6))

        self.modal = m
        self.update_modal()
        self.place_modal()

    def place_modal(self):
        self.modal.update_idletasks()
        mw, mh = self.modal.winfo_reqwidth(), self.modal.winfo_reqheight()
        x = self.root.winfo_x() - mw - 10
        y = self.root.winfo_y()
        if x < 0:  # pet sits at the left edge → open to the right instead
            x = self.root.winfo_x() + self.root.winfo_width() + 10
        y = max(0, min(y, self.root.winfo_screenheight() - mh))
        self.modal.geometry("+%d+%d" % (x, y))

    def update_modal(self):
        if not self.modal:
            return
        state = self.state
        xp = pet.total_xp(state)
        stage, lo, hi = pet.stage_for(xp)
        species_key = state.get("species", pet.DEFAULT_SPECIES)
        sp = pet.SPECIES.get(species_key, pet.SPECIES[pet.DEFAULT_SPECIES])
        hatched = state.get("hatched") or stage != "egg"
        name = (state.get("name") or sp["name"]) if hatched else "???"
        crown = "👑 " if stage == "legendary" else ""
        level = min(99, 1 + int((xp / 10.0) ** 0.5))

        # a hatched pet is at least a hatchling: its next milestone is adult
        if hatched and stage == "egg":
            stage, lo, hi = "hatchling", 0, 200

        self.m_title.config(text="%s %s%s · Lv.%d" % (sp["emoji"], crown, name, level))
        if not hatched:
            self.m_stage.config(text="stage: egg · pick a sprite below to hatch!")
        else:
            self.m_stage.config(text="stage: %s" % stage)

        self.m_bar.delete("all")
        frac = 1.0 if hi is None else max(0.0, min(1.0, (xp - lo) / float(hi - lo)))
        self.m_bar.create_rectangle(0, 0, int(200 * frac), 10, fill=ACCENT, outline="")
        if hi is None:
            self.m_xp.config(text="%d XP · max stage reached" % xp)
        else:
            self.m_xp.config(text="%d XP · %d to %s" % (xp, hi - xp, STAGE_NEXT[stage]))

        status = {"working": ("agents working…", ACCENT),
                  "waiting": ("an agent needs you!" if self.n_input else "waiting for you", WARN),
                  "sleeping": ("everything is idle", MUTED)}[self.mode]
        self.m_status.config(text="● " + status[0], fg=status[1])

        # per-session rows: project — what it is doing right now
        for w in self.m_sessions.winfo_children():
            w.destroy()
        colors = {"working": ACCENT, "busy": ACCENT, "input": "#f38ba8", "ready": WARN}
        ordered = sorted(self.sessions, key=lambda x: x[2] == "idle")  # live first
        for path, age, phase, doing, provider in ordered[:6]:
            row = "%s %s — %s" % (provider, session_label(path, provider), doing)
            tk.Label(self.m_sessions, text="● " + row[:58], bg=CARD,
                     fg=colors.get(phase, MUTED), font=("Menlo", 9)).pack(anchor="w")
        if not self.sessions:
            tk.Label(self.m_sessions, text="no recent sessions", bg=CARD,
                     fg=MUTED, font=("Menlo", 9)).pack(anchor="w")
        self.place_modal()  # row count may have changed the modal height

        for key, c in self.pick.items():
            c.config(highlightbackground=ACCENT if key == species_key else CARD)

    # -- rendering ----------------------------------------------------------
    def draw_effects(self):
        s, c, f = self.scale, self.canvas, self.frame
        if time.time() < self.alert_until:  # just finished → grab attention
            c.create_text(15 * s, 2 * s, text="!", fill=WARN,
                          font=("Menlo", s + 8, "bold"))
        elif self.mode == "working":
            for i in range(3):  # deterministic sparkles orbiting the sprite
                px = (f * 3 + i * 41) % (17 * s)
                py = (f * 5 + i * 29) % (4 * s)
                c.create_text(px + s // 2, py + s, text="✦",
                              fill=WARN, font=("Menlo", s + 2))
        elif self.mode == "waiting":
            c.create_text(15 * s, 2 * s, text="?", fill=WARN,
                          font=("Menlo", s + 6, "bold"))
        else:  # sleeping — z's drift up and right
            for i in range(3):
                phase = ((f // 2) + i * 3) % 9
                c.create_text(12 * s + phase * 2, 5 * s - phase * s // 2,
                              text="z", fill=MUTED, font=("Menlo", s + 2 + i))

    def tick(self):
        now = time.time()
        if now - self.last_poll > 1.0:  # 1 Hz: scan sessions + reload shared state
            self.read_events()
            merged = []
            for path, age, phase, doing, prov in scan_sessions():
                n = self.notif.get(path)
                # a hook event newer than the last transcript write means the
                # prompt is still pending (answering it resumes the transcript)
                if n and n[0] > now - age and phase not in ("ready", "idle"):
                    phase, doing = "input", n[1][:44]
                merged.append((path, age, phase, doing, prov))
            self.sessions = merged
            phases = {s[0]: s[2] for s in self.sessions}
            for path, ph in phases.items():
                prev = self.sess_prev.get(path)
                if ph == "input" and prev not in (None, "input"):
                    # Claude is asking a question / plan approval — ping distinctly
                    self.alert_until = now + 5
                    if self.state.get("sound", True) and now - self.last_sound > SOUND_DEBOUNCE:
                        play_sound(SOUND_INPUT)
                        self.last_sound = now
                elif prev in ("working", "busy") and ph == "ready":
                    # that session's turn really ended (last event = end_turn)
                    self.alert_until = now + 5
                    if self.state.get("sound", True) and now - self.last_sound > SOUND_DEBOUNCE:
                        play_sound(SOUND_READY)
                        self.last_sound = now
                    # the window earns XP too (the statusline pet may not be wired):
                    # +5 per finished turn, banked under a synthetic session key
                    state = pet.load_state()
                    bank = state.setdefault("sessions", {})
                    bank["window"] = bank.get("window", 0) + 5
                    pet.save_state(state)
                    self.state = state
            self.sess_prev = phases
            self.n_active = sum(1 for ph in phases.values() if ph in ("working", "busy"))
            self.n_input = sum(1 for ph in phases.values() if ph == "input")
            self.n_ready = sum(1 for ph in phases.values() if ph == "ready")
            self.mode = ("waiting" if self.n_input        # needs-you outranks all
                         else "working" if self.n_active
                         else "waiting" if self.n_ready else "sleeping")
            self.state = pet.load_state()
            self.last_poll = now
            self.update_modal()

        state = self.state
        xp = pet.total_xp(state)
        stage, _, _ = pet.stage_for(xp)
        species_key = state.get("species", pet.DEFAULT_SPECIES)
        hatched = state.get("hatched") or stage != "egg"
        sprite_key = species_key if hatched else "egg"

        bob_period = {"working": 2, "waiting": 6, "sleeping": 10}[self.mode]
        bob = ((self.frame // bob_period) % 2) * (self.scale // 2)
        rows = PIXELS.get(sprite_key, PIXELS["cat"])["rows"]
        s = self.scale
        ox = (CANVAS_COLS * s - len(rows[0]) * s) // 2
        oy = (CANVAS_ROWS - 4 - len(rows)) * s + bob  # feet above dots + caption

        self.canvas.delete("all")
        # ground shadow: grounds the floating sprite AND widens the clickable
        # area (transparent pixels pass clicks through on macOS)
        cx = CANVAS_COLS * s // 2
        fy = (CANVAS_ROWS - 4) * s
        self.canvas.create_oval(cx - 7 * s, fy - s // 2, cx + 7 * s, fy + s,
                                fill="#2b2b33", outline="")
        blink = self.mode == "sleeping" or (self.mode != "sleeping" and self.frame % 16 == 0)
        paint_pixels(self.canvas, sprite_key, s, ox, oy, eyes_closed=blink)
        self.draw_effects()

        # one status dot per session (only when juggling several):
        # green = working, red = needs your input, yellow = turn done
        live = [x for x in self.sessions if x[2] != "idle"]
        if len(live) > 1:
            dots = live[:8]
            gap = 2 * s
            x0 = (CANVAS_COLS * s - gap * (len(dots) - 1)) // 2
            y = (CANVAS_ROWS - 3) * s + s // 2
            r = max(2, int(s * 0.4))
            for i, (_p, _a, phase, _d, _prov) in enumerate(dots):
                color = {"working": ACCENT, "busy": ACCENT,
                         "ready": WARN}.get(phase, "#f38ba8")
                if phase == "input" and self.frame % 2:  # blink the urgent ones
                    color = WARN
                self.canvas.create_oval(x0 + i * gap - r, y - r,
                                        x0 + i * gap + r, y + r,
                                        fill=color, outline="")

        sp = pet.SPECIES.get(species_key, pet.SPECIES[pet.DEFAULT_SPECIES])
        name = (state.get("name") or sp["name"]) if hatched else "???"
        level = min(99, 1 + int((xp / 10.0) ** 0.5))
        crown = "👑" if stage == "legendary" else ""
        caption = "%s%s · Lv.%d" % (crown, name, level)
        # outlined caption: readable over dark AND white windows behind it
        cap_x, cap_y = CANVAS_COLS * s // 2, (CANVAS_ROWS - 1) * s - s // 2
        cap_f = ("Menlo", max(9, s + 4), "bold")
        for dx2 in (-1, 0, 1):
            for dy2 in (-1, 0, 1):
                if dx2 or dy2:
                    self.canvas.create_text(cap_x + dx2, cap_y + dy2, text=caption,
                                            fill="#15151c", font=cap_f)
        self.canvas.create_text(cap_x, cap_y, text=caption, fill=FG, font=cap_f)

        self.frame += 1
        self.root.after(250, self.tick)


if __name__ == "__main__":
    scale = SCALE
    if "--scale" in sys.argv:
        try:
            scale = max(3, int(sys.argv[sys.argv.index("--scale") + 1]))
        except (IndexError, ValueError):
            pass
    PetWindow(scale).root.mainloop()
