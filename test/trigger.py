#!/usr/bin/env python3
"""session-pet LIVE trigger tester.

Injects synthetic Claude Code transcripts into your REAL ~/.claude/projects so
the RUNNING pet reacts for real: sound + speech bubble + Touch Bar marquee. Lets
you eyeball the callouts without waiting for a genuine session to hit each state.

Usage:
    test/trigger.py permission   # 🔒 needs permission  (Notification hook)
    test/trigger.py decision     # 🤔 needs a decision   (AskUserQuestion)
    test/trigger.py finished     # ✅ finished           (end_turn)
    test/trigger.py stalled      # ⚠️  may need you      (old, no output)
    test/trigger.py all          # run all four, one after another
    test/trigger.py clean        # remove the injected test sessions

The pet must be running (./pet). Each trigger is written first as a "working"
session, then flipped to its target phase a few seconds later, so the phase
TRANSITION fires the ding + bubble (the marquee shows any attention session
regardless). The fake sessions live under a clearly-named test project and are
removed on exit (Ctrl-C) or via `clean`.

Note: "stalled" is marquee-only by design — a stalled session has no ding/bubble.
"""
import atexit
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

HOME = pathlib.Path.home()
PROJ = HOME / ".claude" / "projects" / "-session-pet-trigger-test"
REPO = pathlib.Path(__file__).resolve().parent.parent
EVENTS = REPO / ".state" / "events.jsonl"
KINDS = ["permission", "decision", "finished", "stalled"]


# --- transcript event builders (shapes match native/src/Scanner.swift) --------

def _user(cwd, text):
    return {"type": "user", "cwd": cwd, "message": {"role": "user", "content": text}}


def _assistant_tool(cwd, name, inp):
    return {"type": "assistant", "cwd": cwd, "message": {
        "role": "assistant", "stop_reason": "tool_use",
        "usage": {"input_tokens": 1200, "cache_read_input_tokens": 3400},
        "content": [{"type": "tool_use", "name": name, "input": inp}]}}


def _assistant_text(cwd, text):
    return {"type": "assistant", "cwd": cwd, "message": {
        "role": "assistant", "stop_reason": "end_turn",
        "usage": {"input_tokens": 1200, "cache_read_input_tokens": 3400},
        "content": [{"type": "text", "text": text}]}}


def _write(path, events):
    path.write_text("".join(json.dumps(e) + "\n" for e in events))


def _working(path, cwd):
    _write(path, [_user(cwd, "do the thing"),
                  _assistant_tool(cwd, "Bash", {"command": "npm run build"})])


def _backdate(path, seconds):
    t = time.time() - seconds
    os.utime(path, (t, t))


def _notify(transcript_path, message):
    """Append a Notification hook event to the spool the pet tails."""
    EVENTS.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps({"hook_event_name": "Notification",
                       "transcript_path": str(transcript_path),
                       "message": message}) + "\n"
    with open(EVENTS, "a") as f:
        f.write(line)


def clean():
    if PROJ.exists():
        shutil.rmtree(PROJ)
        print(f"cleaned {PROJ}")


# --- the triggers -------------------------------------------------------------

def setup(kind):
    """Arm one trigger; returns the transcript path so callers can clear it."""
    PROJ.mkdir(parents=True, exist_ok=True)
    name = f"demo-{kind}"
    cwd = str(HOME / name)            # session badge = last path component
    f = PROJ / f"{name}.jsonl"

    if kind == "stalled":
        _working(f, cwd)
        _backdate(f, 360)            # 6 min old + tool_use → stalled
        print(f"  ⚠️  stalled · {name}  (marquee only — no ding by design)")
        return f

    # two-phase: register "working" first so the flip is a real transition
    _working(f, cwd)
    print(f"  … working · {name}")
    time.sleep(3)

    if kind == "permission":
        # keep the working tail; the notif override flips it to input
        _notify(f, "Claude needs your permission to use Bash")
        print(f"  🔒 needs permission · {name}")
    elif kind == "decision":
        _write(f, [_user(cwd, "which approach?"),
                   _assistant_tool(cwd, "AskUserQuestion",
                                   {"description": "Which migration strategy should we use?"})])
        print(f"  🤔 needs a decision · {name}  (arms in ~3s)")
    elif kind == "finished":
        _write(f, [_user(cwd, "build it"),
                   _assistant_text(cwd, "Done — rebuilt the project and all tests pass.")])
        print(f"  ✅ finished · {name}  (arms in ~4s)")
    return f


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "all"
    if arg == "clean":
        clean()
        return
    if arg not in KINDS + ["all"]:
        print(__doc__)
        sys.exit(2)

    running = subprocess.run(["pgrep", "-x", "SessionPet"],
                             capture_output=True).returncode == 0
    if not running:
        print("⚠️  pet is not running — start it with ./pet, then re-run this.\n")

    # clean up no matter how we exit: normal return, Ctrl-C, or a kill
    atexit.register(clean)
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    clean()   # start from a clean slate

    try:
        if arg == "all":
            for k in KINDS:
                f = setup(k)
                print("     holding 15s — watch the pet + Touch Bar…\n")
                time.sleep(15)
                f.unlink(missing_ok=True)   # clear before the next trigger
                time.sleep(2)               # let the pet notice it's gone
        else:
            setup(arg)
            print("\n  Watch the pet + Touch Bar marquee.")
            print("  Click the pet to dismiss the marquee.")
            print("  Press Ctrl-C to clean up.\n")
            while True:
                time.sleep(3600)
    except KeyboardInterrupt:
        print("\ninterrupted")


if __name__ == "__main__":
    main()
