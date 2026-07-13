#!/usr/bin/env python3
"""claude-pet — a codex-pets-style companion that lives in the Claude Code statusline.

Claude Code invokes this script as its statusLine command, passing session JSON on
stdin. The pet mirrors the agent's state (working / waiting / sleeping), animates
while Claude is active, and gains XP from lines of code across ALL sessions —
hatching from an egg into a hatchling, an adult, and finally a legendary form.

Install (statusLine in ~/.claude/settings.json):
    "statusLine": {"type": "command", "command": "python3 ~/Projects/claude-pet/pet.py"}

CLI:
    pet.py species              list available species
    pet.py set species dragon   choose your pet
    pet.py set name Smaug       rename it
    pet.py status               show XP / stage outside the statusline

State lives in .state/state.json next to this script. Stdlib only, always exits 0
(a statusline must never break the harness).
"""
import json
import math
import os
import sys
import time

STATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".state")
STATE_FILE = os.path.join(STATE_DIR, "state.json")

# ---------------------------------------------------------------- species ----
# Each species: default name + animation frames per agent state.
SPECIES = {
    "cat":     {"name": "Mochi",  "emoji": "🐱", "working": ["⌨️", "✨"], "waiting": ["❓", "💭"], "sleeping": ["💤", "😴"]},
    "dragon":  {"name": "Ember",  "emoji": "🐉", "working": ["🔥", "⚡"], "waiting": ["💭", "❓"], "sleeping": ["💤", "🌙"]},
    "crab":    {"name": "Clicky", "emoji": "🦀", "working": ["🔧", "⚙️"], "waiting": ["❓", "🫧"], "sleeping": ["💤", "🌊"]},
    "octopus": {"name": "Inky",   "emoji": "🐙", "working": ["⌨️", "🖋️"], "waiting": ["❓", "🫧"], "sleeping": ["💤", "🌊"]},
    "dino":    {"name": "Rex",    "emoji": "🦖", "working": ["⚡", "💥"], "waiting": ["❓", "💭"], "sleeping": ["💤", "🌋"]},
    "fox":     {"name": "Kit",    "emoji": "🦊", "working": ["✨", "🍃"], "waiting": ["❓", "💭"], "sleeping": ["💤", "🌙"]},
    "alien":   {"name": "Zorp",   "emoji": "👾", "working": ["📡", "⚡"], "waiting": ["❓", "🛸"], "sleeping": ["💤", "🌌"]},
    "turtle":  {"name": "Sage",   "emoji": "🐢", "working": ["🧘", "✨"], "waiting": ["❓", "💭"], "sleeping": ["💤", "🍵"]},
}
DEFAULT_SPECIES = "cat"

# XP thresholds: (min_xp, stage name). XP = lines added+removed + $cost, all sessions.
STAGES = [(0, "egg"), (30, "hatchling"), (200, "adult"), (1000, "legendary")]

# Transcript idle thresholds (seconds since last transcript write).
WORKING_WITHIN = 15
WAITING_WITHIN = 300

DIM, RESET = "\033[2m", "\033[0m"
GREEN, YELLOW, BLUE = "\033[32m", "\033[33m", "\033[34m"


# ------------------------------------------------------------------ state ----
def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)
    except Exception:
        pass  # a statusline must never fail loudly


def total_xp(state):
    return int(sum(state.get("sessions", {}).values()))


def stage_for(xp):
    stage, lo, hi = STAGES[0][1], 0, None
    for i, (threshold, name) in enumerate(STAGES):
        if xp >= threshold:
            stage, lo = name, threshold
            hi = STAGES[i + 1][0] if i + 1 < len(STAGES) else None
    return stage, lo, hi


def progress_bar(xp, lo, hi, width=5):
    if hi is None:
        return "▰" * width
    frac = (xp - lo) / float(hi - lo)
    filled = min(width, int(frac * width))
    return "▰" * filled + "▱" * (width - filled)


# ------------------------------------------------------------------- pet -----
def agent_state(transcript_path):
    """working / waiting / sleeping, from how recently the transcript changed."""
    try:
        age = time.time() - os.path.getmtime(transcript_path)
    except Exception:
        return "waiting"
    if age < WORKING_WITHIN:
        return "working"
    if age < WAITING_WITHIN:
        return "waiting"
    return "sleeping"


def render_pet(state, mode):
    species = SPECIES.get(state.get("species", DEFAULT_SPECIES), SPECIES[DEFAULT_SPECIES])
    xp = total_xp(state)
    stage, lo, hi = stage_for(xp)
    frame_i = int(time.time() * 2)

    if stage == "egg" and not state.get("hatched"):
        body = ["🥚 ", " 🥚", "🥚 ", "🐣"][frame_i % 4] if mode == "working" else "🥚"
        name = "???"
    else:
        effect = species[mode][frame_i % len(species[mode])] if mode == "working" \
            else species[mode][(frame_i // 4) % len(species[mode])]
        body = species["emoji"] + effect
        if stage == "legendary":
            body = "👑" + body
        name = state.get("name") or species["name"]

    level = min(99, 1 + int(math.sqrt(xp / 10.0)))
    bar = progress_bar(xp, lo, hi)
    mood = {
        "working": GREEN + "hard at work" + RESET,
        "waiting": YELLOW + "waiting for you" + RESET,
        "sleeping": BLUE + "zzz" + RESET,
    }[mode]
    return "%s %s Lv.%d %s · %s" % (body, name, level, bar, mood)


# ----------------------------------------------------------------- main ------
def statusline():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}

    state = load_state()
    cost = payload.get("cost") or {}
    sid = payload.get("session_id")
    if sid:
        xp_now = (cost.get("total_lines_added") or 0) + (cost.get("total_lines_removed") or 0) \
            + int(cost.get("total_cost_usd") or 0)
        sessions = state.setdefault("sessions", {})
        if xp_now > sessions.get(sid, 0):
            sessions[sid] = xp_now
        if len(sessions) > 300:  # prune oldest entries, keep the XP they earned
            state["banked_xp"] = state.get("banked_xp", 0)
            for old in list(sessions)[:-300]:
                state["banked_xp"] += sessions.pop(old)
        save_state(state)
    if state.get("banked_xp"):
        state.setdefault("sessions", {})["_banked"] = state["banked_xp"]

    mode = agent_state(payload.get("transcript_path") or "")
    pet = render_pet(state, mode)

    model = (payload.get("model") or {}).get("display_name") or ""
    cwd = payload.get("cwd") or ""
    home = os.path.expanduser("~")
    if cwd.startswith(home):
        cwd = "~" + cwd[len(home):]
    added = cost.get("total_lines_added") or 0
    removed = cost.get("total_lines_removed") or 0
    usd = cost.get("total_cost_usd") or 0.0

    info = " · ".join(x for x in [model, os.path.basename(cwd.rstrip("/")) or cwd,
                                  "+%d -%d" % (added, removed), "$%.2f" % usd] if x)
    print("%s %s| %s%s" % (pet, DIM, info, RESET))


def cli(args):
    state = load_state()
    if args[0] == "species":
        for key, sp in SPECIES.items():
            marker = "←" if key == state.get("species", DEFAULT_SPECIES) else " "
            print("%s %-8s %s %s" % (sp["emoji"], key, sp["name"], marker))
    elif args[0] == "set" and len(args) == 3 and args[1] in ("species", "name"):
        if args[1] == "species" and args[2] not in SPECIES:
            print("unknown species %r — run `pet.py species`" % args[2])
            return
        state[args[1]] = args[2]
        save_state(state)
        print("ok — %s = %s" % (args[1], args[2]))
    elif args[0] == "status":
        xp = total_xp(load_state())
        stage, lo, hi = stage_for(xp)
        sp = SPECIES.get(state.get("species", DEFAULT_SPECIES), SPECIES[DEFAULT_SPECIES])
        name = "???" if stage == "egg" else (state.get("name") or sp["name"])
        print("%s %s — %s, %d XP %s" % (sp["emoji"], name, stage, xp, progress_bar(xp, lo, hi)))
    else:
        print(__doc__)


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1:
            cli(sys.argv[1:])
        else:
            statusline()
    except Exception:
        print("🐾")  # never break the statusline
    sys.exit(0)
