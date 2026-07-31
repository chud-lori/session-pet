#!/usr/bin/env python3
"""session-pet Linux core — session scanning + pet state daemon.

Faithful Python port of the Mac app's platform-neutral half
(native/src/Scanner.swift, State.swift, and the tick/sound/XP logic of
App.swift). The native face (linux/face, Rust + GTK) spawns this process and
speaks NDJSON with it:

  stdout (core → face), one JSON object per line:
    {"type":"snapshot", ...}   full pet + session state, every poll (~1s)
    {"type":"sound", "kind":"ready"|"input", "volume":1.0, "double":bool,
     "path":"/abs/file"}       play this now (input sounds repeat via "double")

  stdin (face → core), one JSON object per line:
    {"cmd":"ack", "path":...}          user clicked a session card
    {"cmd":"set", "key":..., "value":...}   species / sound / walk / name / form
    {"cmd":"pick_species", "key":...}       hatch + choose species

State (.state/state.json) and hook events (.state/events.jsonl) are shared
with the Mac app and pet.py — same file, same schema. Stdlib only.

CLI:
    core.py --once     one scan, pretty-print the snapshot, exit (debugging)
    core.py --serve    daemon mode (what the face runs)
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------- paths ----

HOME = os.path.expanduser("~")
# test override: point both providers at a fake home (fixtures) if set
PET_HOME = os.environ.get("SESSION_PET_HOME", HOME)
PET_LOG = os.environ.get("SESSION_PET_LOG") == "1"
# repo root when run from a clone; the face overrides this for no-clone
# installs (binary extracts core.py under ~/.local/share/session-pet)
PET_ROOT = os.environ.get(
    "SESSION_PET_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE_PATH = os.path.join(PET_ROOT, ".state", "state.json")
EVENTS_PATH = os.path.join(PET_ROOT, ".state", "events.jsonl")
SOUNDS_DIR = os.path.join(PET_ROOT, "sounds")

WORKING_WITHIN = 15.0
WAITING_WITHIN = 300.0
BUSY_GRACE = 300.0
RECENT_WINDOW = 3600.0
SOUND_DEBOUNCE = 8.0
INPUT_TOOLS = {"AskUserQuestion", "ExitPlanMode"}
READY_CONFIRM = 4.0   # hold before trusting a Claude end_turn (stop hooks)
READY_NAG = 180.0     # unacked "ready" fades to idle after this

# freedesktop sound theme — present on most desktop installs; a missing file
# falls back silently to no sound (face skips unplayable paths)
DEFAULT_READY = "/usr/share/sounds/freedesktop/stereo/complete.oga"
DEFAULT_INPUT = "/usr/share/sounds/freedesktop/stereo/dialog-information.oga"


def log(msg):
    if not PET_LOG:
        return
    stamp = datetime.now(timezone.utc).isoformat()
    try:
        with open("/tmp/session-pet-core.log", "a") as f:
            f.write(f"{stamp} {msg}\n")
    except OSError:
        pass


def tildify(path):
    return "~" + path[len(HOME):] if path.startswith(HOME) else path


def fmt_age(age):
    if age < 60:
        return f"{int(age)}s"
    if age < 3600:
        return f"{int(age / 60)}m"
    return f"{int(age / 3600)}h"


def jload(text):
    try:
        v = json.loads(text)
        return v if isinstance(v, dict) else None
    except (json.JSONDecodeError, ValueError):
        return None


# ---------------------------------------------------------------- state ----
# Port of State.swift — shared .state/state.json (same file as pet.py / Swift).

STAGES = [(0, "egg"), (30, "hatchling"), (200, "adult"), (1000, "legendary")]
STAGE_ORDER = [name for _, name in STAGES]

# Evolution rules — mirrors SPECIES[...]["evolve"] in pet.py (this file is
# stdlib-only and standalone, same duplication as STAGES above).
EVOLVE = {"agumon": ("adult", "greymon")}


def evolution_chain(species, stage):
    """Forms unlocked at this stage, base species first (triggered EVOLVE
    rules: agumon → [agumon, greymon] at adult)."""
    si = STAGE_ORDER.index(stage) if stage in STAGE_ORDER else 0
    chain = [species]
    while species in EVOLVE:
        at, to = EVOLVE[species]
        if at not in STAGE_ORDER or si < STAGE_ORDER.index(at) or to in chain:
            break
        chain.append(to)
        species = to
    return chain


def sprite_for(species, stage, form=None):
    """Species key to actually show: the latest unlocked evolution, unless the
    user rolled back to an earlier unlocked form (state['form'])."""
    chain = evolution_chain(species, stage)
    return form if form in chain else chain[-1]


def load_state():
    try:
        with open(STATE_PATH, "rb") as f:
            data = f.read()
    except OSError:
        return {}
    parsed = jload(data.decode("utf-8", "replace"))
    if parsed is not None:
        return parsed
    # corrupt but non-empty: keep one .bak so XP history is recoverable
    if data:
        bak = STATE_PATH + ".bak"
        if not os.path.exists(bak):
            try:
                with open(bak, "wb") as f:
                    f.write(data)
            except OSError:
                pass
    return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_PATH)
    except OSError:
        pass


def total_xp(state):
    banked = state.get("banked_xp", 0)
    banked = banked if isinstance(banked, (int, float)) else 0
    sessions = state.get("sessions", {})
    if not isinstance(sessions, dict):
        sessions = {}
    return int(banked) + sum(
        int(v) for v in sessions.values() if isinstance(v, (int, float)))


def stage_for(xp):
    stage, lo, hi = "egg", 0, None
    for i, (threshold, name) in enumerate(STAGES):
        if xp >= threshold:
            stage, lo = name, threshold
            hi = STAGES[i + 1][0] if i + 1 < len(STAGES) else None
    return stage, lo, hi


# -------------------------------------------------------------- scanning ----
# Port of Scanner.swift. Comments preserved where the logic is subtle.


class TailInfo:
    __slots__ = ("stop", "tool", "detail", "ctx", "snippet", "title", "cwd",
                 "custom_title", "agent_name", "new_turn", "new_turn_at",
                 "hook_continuation")

    def __init__(self):
        self.stop = None
        self.tool = None
        self.detail = ""
        self.ctx = None
        self.snippet = ""
        self.title = None
        self.cwd = None
        self.custom_title = None   # manual /rename — beats the AI title
        self.agent_name = None     # user-assigned agent name — beats dir badge
        self.new_turn = False      # real user prompt AFTER the last end_turn
        self.new_turn_at = None    # epoch seconds of that prompt, when known
        self.hook_continuation = False  # Stop-hook feedback after end_turn


def ack_key(sess):
    # snippet alone is often "" (input/stalled turns); ctx grows every turn,
    # so together they identify a turn without depending on volatile mtime
    return f"{sess['snippet']}|{sess['ctx'] or 0}"


def tail_lines(path, want=65536):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            start = size - want if size > want else 0
            f.seek(start)
            data = f.read()
    except OSError:
        return []
    # lossy decode — a stray invalid byte must never nil the whole tail
    lines = data.decode("utf-8", "replace").split("\n")
    lines = [l for l in lines if l]
    # the first line of a mid-file chunk is almost certainly partial
    if start > 0 and lines:
        lines.pop(0)
    return lines


# --- open-session detection -------------------------------------------------
# A quiet transcript can't distinguish "terminal still open" from "closed" —
# but the process list can: open sessions run as `claude --resume <id-or-name>`.
# Refreshed every ~15s; matched against transcript filename stems and rename
# names (agent-name / custom-title).
open_session_ids = set()
# path → {"pid", "cwd", "resume", "chain"} for the process running that
# session; "chain" is the ancestor pid list the face matches against
# _NET_WM_PID to find (and raise) the terminal window. See jump support.
agent_procs = {}


def _proc_stat_ppid(pid):
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            data = f.read()
    except OSError:
        return None
    # comm (field 2) may contain spaces/parens — split after the LAST ')'
    close = data.rfind(b")")
    if close < 0:
        return None
    rest = data[close + 2:].split(b" ")
    try:
        return int(rest[1])  # state, ppid
    except (IndexError, ValueError):
        return None


def _proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
    except OSError:
        return []
    return [a for a in raw.decode("utf-8", "replace").split("\0") if a]


def refresh_open_sessions(sessions=()):
    """Scan /proc once: which sessions are open, and what runs each of them.

    Everything comes from /proc — no ps, no lsof, no external tools. Agent
    processes are found by argv[0], their cwd by the /proc/<pid>/cwd symlink,
    and their ancestry by walking ppid up to (but not including) init.
    """
    global open_session_ids, agent_procs
    ids = set()
    candidates = []
    try:
        pids = [int(d) for d in os.listdir("/proc") if d.isdigit()]
    except OSError:
        return
    for pid in pids:
        argv = _proc_cmdline(pid)
        if not argv:
            continue
        # argv[0] is the agent only for native installs; an npm install runs
        # it as `node …/bin/claude`, and wrappers/shims add more layers — so
        # look for the agent anywhere in the leading arguments
        if not any(os.path.basename(a) in ("claude", "codex")
                   for a in argv[:3]):
            continue
        resume = None
        if "--resume" in argv:
            i = argv.index("--resume")
            if i + 1 < len(argv):
                resume = argv[i + 1]
                ids.add(resume)
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            cwd = None
        candidates.append({"pid": pid, "cwd": cwd, "resume": resume})
    open_session_ids = ids

    procs = {}
    for sess in sessions:
        stem = os.path.splitext(os.path.basename(sess["path"]))[0]
        want = sess.get("cwd")
        if want and want.startswith("~"):
            want = HOME + want[1:]
        match = None
        for c in candidates:
            if c["resume"] and c["resume"] == stem:
                match = c
                break
            if want and c["cwd"] == want:
                match = c
                break
        if not match:
            continue
        # ancestor chain: the terminal emulator is one of these pids
        chain, pid = [], match["pid"]
        for _ in range(20):
            ppid = _proc_stat_ppid(pid)
            if not ppid or ppid <= 1:
                break
            chain.append(ppid)
            pid = ppid
        procs[sess["path"]] = {**match, "chain": chain}
    agent_procs = procs
    log(f"agents: {len(candidates)} found, {len(procs)} matched to sessions; "
        f"cwds={[c['cwd'] for c in candidates]}")


# the session's START directory = the cwd on the earliest events; immutable,
# so cached forever per path ("" caches a miss)
start_cwd_cache = {}


def claude_start_cwd(path):
    if path in start_cwd_cache:
        c = start_cwd_cache[path]
        return c or None
    found = ""
    try:
        with open(path, "rb") as f:
            head = f.read(16384)
        for line in head.decode("utf-8", "replace").split("\n")[:25]:
            ev = jload(line)
            if ev and isinstance(ev.get("cwd"), str):
                found = ev["cwd"]
                break
    except OSError:
        pass
    start_cwd_cache[path] = found
    return found or None


_ISO_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(\.\d+)?"
    r"(Z|[+-]\d{2}:?\d{2})?$")


def parse_iso(s):
    m = _ISO_RE.match(s.strip())
    if not m:
        return None
    y, mo, d, h, mi, sec = (int(m.group(i)) for i in range(1, 7))
    frac = float(m.group(7) or 0)
    tz = m.group(8)
    if tz in (None, "Z"):
        off = 0
    else:
        sign = 1 if tz[0] == "+" else -1
        tz = tz[1:].replace(":", "")
        off = sign * (int(tz[:2]) * 3600 + int(tz[2:] or 0) * 60)
    try:
        dt = datetime(y, mo, d, h, mi, sec, tzinfo=timezone.utc)
    except ValueError:
        return None
    return dt.timestamp() + frac - off


def snippet_of(s):
    return (s.split("\n", 1)[0])[:64]


# normalized: stop ∈ end_turn | tool_use | pending | writing | None
def tail_info_claude(path):
    info = parse_claude_tail(tail_lines(path))
    if info.stop is None:
        # no decisive assistant event in the last 64KB (huge tool_results) —
        # grow the backwards read once
        info = parse_claude_tail(tail_lines(path, want=524288))
    return info


def parse_claude_tail(lines):
    info = TailInfo()
    decided = False
    for line in reversed(lines):
        t = line.strip()
        if not t:
            continue
        ev = jload(t)
        if ev is None:
            if not decided:
                info.stop = "writing"
                decided = True
            continue
        etype = ev.get("type")
        if info.cwd is None and isinstance(ev.get("cwd"), str):
            info.cwd = ev["cwd"]
        if info.title is None and etype == "ai-title":
            info.title = ev.get("aiTitle")
        # manual renames beat everything: /rename writes custom-title, naming
        # the agent writes agent-name — user intent > derived names
        if info.custom_title is None and etype == "custom-title":
            info.custom_title = ev.get("customTitle")
        if info.agent_name is None and etype == "agent-name":
            info.agent_name = ev.get("agentName")
        if decided:
            continue  # keep scanning the tail for names/cwd (cached by mtime)
        if etype == "user" and not info.hook_continuation:
            # hook-feedback events are isMeta, but they are THE signal that a
            # blocking Stop hook is continuing the turn — an end_turn followed
            # by one is intermediate, not final
            c = (ev.get("message") or {}).get("content") \
                if isinstance(ev.get("message"), dict) else None
            if isinstance(c, str) and c.startswith("Stop hook feedback"):
                info.hook_continuation = True
        if etype == "user" and not info.new_turn and ev.get("isMeta") is not True:
            # a REAL prompt (string content / text blocks, not a tool_result)
            # newer than the last assistant event = a new turn is starting,
            # even though Claude hasn't written its first event yet (thinking)
            content = (ev.get("message") or {}).get("content") \
                if isinstance(ev.get("message"), dict) else None
            is_prompt = False
            if isinstance(content, str):
                # local-command echoes and interruption markers are meta
                is_prompt = (not content.startswith("<local-command")
                             and not content.startswith("[Request interrupted"))
            elif isinstance(content, list):
                is_prompt = not any(
                    isinstance(b, dict) and b.get("type") == "tool_result"
                    for b in content)
            if is_prompt:
                info.new_turn = True
                # when the prompt itself happened — an unanswered prompt from
                # hours ago (closed mid-send) is abandoned, not "processing"
                ts = ev.get("timestamp")
                if isinstance(ts, str):
                    info.new_turn_at = parse_iso(ts)
        if etype == "assistant":
            msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
            info.stop = msg.get("stop_reason")
            usage = msg.get("usage")
            if isinstance(usage, dict):
                # input + cache reads ≈ the session's live context size
                info.ctx = sum(
                    int(usage[k]) for k in ("input_tokens",
                                            "cache_read_input_tokens",
                                            "cache_creation_input_tokens")
                    if isinstance(usage.get(k), (int, float)))
            content = msg.get("content")
            blocks = content if isinstance(content, list) else []
            for block in reversed(blocks):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use" and info.tool is None:
                    inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                    detail = (inp.get("description") or inp.get("command")
                              or inp.get("file_path") or inp.get("pattern") or "")
                    if not isinstance(detail, str):
                        detail = ""
                    info.tool = block.get("name")
                    info.detail = detail.split("\n", 1)[0][:44]
                if block.get("type") == "text" and not info.snippet:
                    info.snippet = snippet_of(block.get("text") or "")
            decided = True  # keep scanning only for title/cwd
            continue
        # anything else — tool_results, stop-hook feedback (user events),
        # housekeeping — is skipped: only the newest ASSISTANT event tells
        # the truth about the session
    return info


# exec commands arrive either as one string or as an argv array of strings
def cmd_string(v):
    if isinstance(v, str):
        return v
    if isinstance(v, list):
        return " ".join(x for x in v if isinstance(x, str))
    return ""


def tail_info_codex(path):
    info = parse_codex_tail(tail_lines(path))
    if info.stop is None:
        info = parse_codex_tail(tail_lines(path, want=524288))
    return info


def parse_codex_tail(lines):
    info = TailInfo()
    decided = False
    scanned = 0
    for line in reversed(lines):
        t = line.strip()
        if not t:
            continue
        scanned += 1
        # keep scanning a bit past the decisive event to also pick up
        # token_count (written just before task_complete)
        if scanned > 40 or (decided and info.ctx is not None):
            break
        ev = jload(t)
        if ev is None:
            if not decided:
                info.stop = "writing"
                decided = True
            continue
        p = ev.get("payload") if isinstance(ev.get("payload"), dict) else {}
        pt = p.get("type")
        if ev.get("type") == "event_msg" and pt == "token_count" and info.ctx is None:
            inf = p.get("info") if isinstance(p.get("info"), dict) else {}
            usage = inf.get("total_token_usage") \
                if isinstance(inf.get("total_token_usage"), dict) else {}
            v = usage.get("input_tokens")
            info.ctx = int(v) if isinstance(v, (int, float)) else 0
            continue
        if decided:
            continue
        etype = ev.get("type")
        if etype == "event_msg":
            if pt == "task_complete":
                info.stop = "end_turn"
                info.snippet = snippet_of(p.get("last_agent_message") or "")
                decided = True
            elif pt in ("request_user_input", "elicitation_request"):
                info.stop = "tool_use"
                info.tool = "AskUserQuestion"
                info.detail = "question for you"
                decided = True
            elif pt == "exec_command_begin":
                info.stop = "tool_use"
                info.tool = "shell"
                info.detail = cmd_string(p.get("command"))[:44]
                decided = True
            elif pt in ("task_started", "user_message"):
                info.stop = "pending"
                decided = True
        elif etype == "response_item":
            if pt == "function_call":
                info.stop = "tool_use"
                info.tool = p.get("name") or "tool"
                args = p.get("arguments")
                info.detail = (args if isinstance(args, str) else "")[:44]
                decided = True
            elif pt == "local_shell_call":
                action = p.get("action") if isinstance(p.get("action"), dict) else {}
                info.stop = "tool_use"
                info.tool = "shell"
                info.detail = cmd_string(action.get("command"))[:44]
                decided = True
            elif pt in ("message", "function_call_output"):
                info.stop = "pending"
                decided = True
    return info


def claude_transcripts():
    base = os.path.join(PET_HOME, ".claude", "projects")
    out = []
    try:
        dirs = os.listdir(base)
    except OSError:
        return out
    for d in dirs:
        dpath = os.path.join(base, d)
        try:
            files = os.listdir(dpath)
        except OSError:
            continue
        out.extend(os.path.join(dpath, f) for f in files if f.endswith(".jsonl"))
    return out


def codex_transcripts():
    # rollouts live at sessions/YYYY/MM/DD/rollout-*.jsonl — scan today plus a
    # few older day-dirs: multi-day sessions keep appending to the file in the
    # dir where they STARTED
    out = []
    now = datetime.now()
    for delta in (0, 1, 2, 3):
        day = now - timedelta(days=delta)
        d = os.path.join(PET_HOME, ".codex", "sessions", day.strftime("%Y/%m/%d"))
        try:
            files = os.listdir(d)
        except OSError:
            continue
        out.extend(os.path.join(d, f) for f in files
                   if f.startswith("rollout-") and f.endswith(".jsonl"))
    return out


def project_label(path, provider):
    if provider == "codex":
        # cwd lives in the session_meta first line
        try:
            with open(path, "rb") as f:
                head = f.read(4096)
            first = head.decode("utf-8", "replace").split("\n", 1)[0]
            ev = jload(first)
            if ev:
                p = ev.get("payload") if isinstance(ev.get("payload"), dict) else {}
                if isinstance(p.get("cwd"), str):
                    return tildify(p["cwd"])
        except OSError:
            pass
        return "codex"
    label = os.path.basename(os.path.dirname(path))
    home_key = "-" + HOME.strip("/").replace("/", "-") + "-"
    if label.startswith(home_key):
        label = "~/" + label[len(home_key):]
    return label


stop_cache = {}   # path → (mtime, TailInfo)
ready_hold = {}   # path → (turn key, first seen)


def scan_sessions():
    now = time.time()
    out = []
    sources = [("claude", claude_transcripts(), tail_info_claude),
               ("codex", codex_transcripts(), tail_info_codex)]
    for provider, paths, tailer in sources:
        for path in paths:
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            age = now - mtime
            # quiet-but-OPEN sessions (running `claude --resume …`) stay
            # listed no matter how old; everything else ages out at
            # RECENT_WINDOW. 48h hard cap keeps the parse set bounded.
            if age > 172800:
                continue
            cached = stop_cache.get(path)
            if cached and cached[0] == mtime:
                info = cached[1]
            else:
                info = tailer(path)
                stop_cache[path] = (mtime, info)
            if age > RECENT_WINDOW:
                stem = os.path.splitext(os.path.basename(path))[0]
                is_open = (stem in open_session_ids
                           or (info.agent_name in open_session_ids
                               if info.agent_name else False)
                           or (info.custom_title in open_session_ids
                               if info.custom_title else False))
                if not is_open:
                    continue
                label = (info.custom_title or info.title
                         or (tildify(info.cwd) if info.cwd else None)
                         or project_label(path, provider))
                cwd = (claude_start_cwd(path) if provider == "claude" else None) \
                    or info.cwd
                project = info.agent_name or os.path.basename(cwd or label)
                if not project or project == "~":
                    project = provider
                out.append({"path": path, "age": age, "phase": "idle",
                            "doing": f"open — quiet {fmt_age(age)}",
                            "provider": provider, "ctx": info.ctx,
                            "snippet": info.snippet, "label": label,
                            "cwd": tildify(cwd) if cwd else None,
                            "project": project})
                continue
            phase, doing = "", ""
            if (info.stop == "tool_use" and info.tool in INPUT_TOOLS
                    and age > 3):
                phase, doing = "input", "needs your answer"
            elif info.stop in ("end_turn", "stop_sequence"):
                if info.hook_continuation and age < BUSY_GRACE:
                    # a blocking Stop hook is continuing the turn — this
                    # end_turn is intermediate, no ding
                    phase, doing = "working", "running stop hooks…"
                elif (info.new_turn and age < BUSY_GRACE
                      and (now - info.new_turn_at < 180
                           if info.new_turn_at else True)):
                    # only a RECENT unanswered prompt means "processing" —
                    # an old one is an abandoned send, not an active turn
                    phase, doing = "working", "processing your prompt…"
                elif age < WAITING_WITHIN:
                    # end_turn is authoritative even at fresh mtime —
                    # housekeeping events keep touching the file after a turn
                    phase, doing = "ready", "finished — waiting for you"
                    key = f"{info.snippet}|{info.ctx or 0}"
                    # seed from the event's real age, not first-noticed time —
                    # otherwise a pet restart resets every fade timer
                    if ready_hold.get(path, (None,))[0] != key:
                        ready_hold[path] = (key, now - min(age, READY_NAG))
                    ready_since = now - ready_hold[path][1]
                    if (provider == "claude" and ready_since < READY_CONFIRM
                            and age < READY_CONFIRM + 30):
                        # a Claude end_turn may be a stop-hook/queued-msg
                        # intermediate: hold until it survives READY_CONFIRM
                        phase, doing = "working", "finishing up…"
                    elif ready_since > READY_NAG:
                        # hybrid ack: unclicked for a while = you saw it;
                        # fade to idle instead of nagging forever
                        phase, doing = "idle", "done"
                else:
                    phase, doing = "idle", "done"
            elif age < WORKING_WITHIN:
                phase = "working"
                if info.stop == "tool_use" and info.tool:
                    doing = info.tool + (f" · {info.detail}" if info.detail else "")
                else:
                    doing = "thinking / writing"
            elif age < BUSY_GRACE:
                phase = "busy"
                doing = f"{info.tool} · still running" if info.tool else "still running"
            elif info.stop in ("tool_use", "pending", "writing"):
                # blocked mid-turn (permission prompt, hung tool, crash) —
                # keep it visible instead of vanishing; also preserves
                # prev-phase continuity so a late end_turn still dings
                phase, doing = "stalled", "no output — may need you"
            else:
                continue
            disp_age = age
            if provider == "claude":
                # subagents write transcripts under <session-id>/subagents/**
                # — while they run, the parent transcript is idle but the
                # SESSION is not
                sub_dir = path[:-6] + "/subagents"
                active = 0
                newest_sub = float("inf")
                if os.path.isdir(sub_dir):
                    for root, _dirs, files in os.walk(sub_dir):
                        for f in files:
                            if not f.endswith(".jsonl"):
                                continue
                            try:
                                sage = now - os.stat(os.path.join(root, f)).st_mtime
                            except OSError:
                                continue
                            newest_sub = min(newest_sub, sage)
                            if sage < WORKING_WITHIN:
                                active += 1
                if active > 0 and phase != "input":
                    phase = "working"
                    doing = f"{active} subagent{'' if active == 1 else 's'} working…"
                    disp_age = min(disp_age, newest_sub)
            # cwd: real event cwd when present, else the decoded projectLabel
            # path (display-only). Session START dir, not current dir.
            fallback = project_label(path, provider)
            start_cwd = claude_start_cwd(path) if provider == "claude" else None
            cwd = (start_cwd or info.cwd
                   or (fallback if fallback.startswith(("~", "/")) else None))
            # badge: the user's rename (agent-name) wins; else dir name
            project = info.agent_name or os.path.basename(cwd or fallback)
            if not project or project == "~":
                project = provider
            # title: manual /rename wins; else AI title; else path
            label = (info.custom_title or info.title
                     or (tildify(info.cwd) if info.cwd else None) or fallback)
            out.append({"path": path, "age": disp_age, "phase": phase,
                        "doing": doing, "provider": provider, "ctx": info.ctx,
                        "snippet": info.snippet, "label": label,
                        "cwd": cwd, "project": project})
    out.sort(key=lambda s: s["age"])
    return out


# ------------------------------------------------------------------ core ----
# Port of App.swift's tick: hook-event spool, ack bookkeeping, phase
# transitions → sounds + XP, the re-alert pager, and mode aggregation.


def sound_path(kind, state):
    key, fallback = (("soundReady", DEFAULT_READY) if kind == "ready"
                     else ("soundInput", DEFAULT_INPUT))
    v = state.get(key)
    if not isinstance(v, str) or not v:
        return fallback
    p = v if v.startswith("/") else os.path.join(SOUNDS_DIR, v)
    return p if os.path.exists(p) else fallback


class Core:
    def __init__(self):
        self.last_sound = 0.0
        self.last_ping = 0.0
        self.last_ps_scan = 0.0
        self.realerts = {}     # path → {key, count, last_at}
        self.ev_offset = 0
        self.ev_primed = False
        self.notif = {}        # path → (ts, message)
        self.prev_phases = {}
        self.acked = {}        # path → acked turn key
        self.alert_until = 0.0
        self.excite_until = 0.0
        self.out_lock = threading.Lock()

    def emit(self, obj):
        with self.out_lock:
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()

    # --- hook-event spool (.state/events.jsonl, written by the Claude hook)
    def read_events(self):
        try:
            size = os.stat(EVENTS_PATH).st_size
        except OSError:
            if not self.ev_primed:
                # no spool at launch = nothing stale to skip; whatever appears
                # later is fresh and must be parsed from byte 0
                self.ev_primed = True
                self.ev_offset = 0
            return
        if not self.ev_primed:
            # first read after launch: skip everything already in the file —
            # stale notifications must never replay as fresh
            self.ev_primed = True
            self.ev_offset = size
            return
        if size < self.ev_offset:
            self.ev_offset = 0
        if size == self.ev_offset:
            return
        try:
            with open(EVENTS_PATH, "rb") as f:
                f.seek(self.ev_offset)
                data = f.read()
        except OSError:
            return
        # consume only up to the last complete line — advancing past a
        # half-appended line would drop that notification forever
        nl = data.rfind(b"\n")
        if nl < 0:
            return
        complete = data[:nl + 1]
        self.ev_offset += len(complete)
        for line in complete.decode("utf-8", "replace").split("\n"):
            ev = jload(line)
            if not ev or ev.get("hook_event_name") != "Notification":
                continue
            path = ev.get("transcript_path") or ""
            self.notif[path] = (time.time(),
                                ev.get("message") or "needs your attention")
        if size > 262144 and self.ev_offset == size:
            # keep the hook log from growing forever — but only truncate when
            # we consumed everything AND nothing new landed since our stat
            try:
                if os.stat(EVENTS_PATH).st_size == size:
                    with open(EVENTS_PATH, "wb"):
                        pass
                    self.ev_offset = 0
            except OSError:
                pass

    def play_sound(self, kind, state, now):
        if not state.get("sound", True):
            return
        # the needs-input ping has its own debounce clock — a ready ding
        # moments earlier must never mask the more urgent sound
        if kind == "input":
            if now - self.last_ping <= SOUND_DEBOUNCE:
                return
            self.last_ping = now
        else:
            if now - self.last_sound <= SOUND_DEBOUNCE:
                return
            self.last_sound = now
        vol = state.get("soundVolume")
        if not isinstance(vol, (int, float)):
            vol = 1.6 if kind == "input" else 1.0
        # double-ping pattern: repetition beats loudness through masking
        self.emit({"type": "sound", "kind": kind,
                   "volume": min(max(float(vol), 0.1), 3.0),
                   "double": kind == "input",
                   "path": sound_path(kind, state)})

    def poll(self):
        now = time.time()
        if now - self.last_ps_scan > 15:
            # matched against the previous tick's sessions so open_session_ids
            # is already fresh when scan_sessions runs below
            self.last_ps_scan = now
            refresh_open_sessions(self.prev_sessions)
        self.read_events()
        sessions = scan_sessions()
        for s in sessions:
            n = self.notif.get(s["path"])
            if n and n[0] > now - s["age"] and s["phase"] not in ("ready", "idle"):
                s["phase"] = "input"
                s["doing"] = n[1][:44]
            elif s["phase"] == "ready" and self.acked.get(s["path"]) == ack_key(s):
                # acknowledged and same turn since → plain done, no nagging
                s["phase"] = "idle"
                s["doing"] = "done"
        phases = {s["path"]: s["phase"] for s in sessions}
        state = load_state()
        unhide = False
        for path, ph in phases.items():
            prev = self.prev_phases.get(path)
            if PET_LOG and prev != ph:
                log(f"{os.path.basename(path)} {prev or '-'}->{ph}")
            if ph == "input" and prev is not None and prev != "input":
                unhide = True  # needs-input overrides movie mode (face-side)
                self.alert_until = now + 5
                self.excite_until = now + 3  # visible even when muted
                self.play_sound("input", state, now)
            elif prev in ("working", "busy", "stalled") and ph == "ready":
                # stalled counts too: a long-silent session that finally
                # finishes must still ding and bank XP
                self.alert_until = now + 5
                self.excite_until = now + 3
                self.play_sound("ready", state, now)
                bank = state.get("sessions")
                if not isinstance(bank, dict):
                    bank = {}
                bank["window"] = int(bank.get("window") or 0) + 5
                state["sessions"] = bank
                save_state(state)
        self.prev_phases = phases
        # pager pattern: while a needs-input session stays unacknowledged,
        # re-ping every 45s (max 3 extra) — one chime is easy to miss under
        # video/music; acking the card or answering stops it
        for s in sessions:
            if s["phase"] != "input" or self.acked.get(s["path"]) == ack_key(s):
                continue
            key = ack_key(s)
            r = self.realerts.get(s["path"]) or {"key": key, "count": 0, "last_at": now}
            if r["key"] != key:
                r = {"key": key, "count": 0, "last_at": now}
            if r["count"] < 3 and now - r["last_at"] > 45:
                r["count"] += 1
                r["last_at"] = now
                self.alert_until = now + 5
                self.excite_until = now + 3
                self.last_ping = 0  # re-alert bypasses the debounce window
                self.play_sound("input", state, now)
            self.realerts[s["path"]] = r
        n_active = sum(1 for p in phases.values() if p in ("working", "busy"))
        n_input = sum(1 for p in phases.values() if p == "input")
        n_ready = sum(1 for p in phases.values() if p == "ready")
        n_stalled = sum(1 for p in phases.values() if p == "stalled")
        mode = ("waiting" if n_input > 0
                else "working" if n_active > 0
                else "waiting" if n_ready > 0 or n_stalled > 0
                else "sleeping")
        needs_attention = any(
            s["phase"] in ("ready", "input", "stalled")
            and self.acked.get(s["path"]) != ack_key(s)
            for s in sessions)
        xp = total_xp(state)
        stage, lo, hi = stage_for(xp)
        hatched = bool(state.get("hatched")) or stage != "egg"
        if hatched and stage == "egg":
            stage = "hatchling"
        level = min(99, 1 + int((xp / 10.0) ** 0.5))
        return {
            "type": "snapshot", "now": now, "mode": mode,
            "needs_attention": needs_attention, "unhide": unhide,
            "alert_until": self.alert_until, "excite_until": self.excite_until,
            "pet": {
                "species": state.get("species") or "cat",
                # what the face should draw: species + any triggered evolution,
                # honoring an evolution rollback ("species" stays raw so the
                # picker keeps its selection); "forms" feeds the settings
                # dropdown — only meaningful when >1 form is unlocked
                "sprite": sprite_for(state.get("species") or "cat", stage,
                                     state.get("form")),
                "forms": evolution_chain(state.get("species") or "cat", stage),
                "name": state.get("name"),
                "hatched": hatched, "stage": stage,
                "xp": xp, "stage_lo": lo, "stage_hi": hi, "level": level,
                "sound": bool(state.get("sound", True)),
                "walk": bool(state.get("walk", True)),
            },
            "sessions": [
                {**s, "term_pids": agent_procs.get(s["path"], {}).get("chain", [])}
                for s in sessions
            ],
        }

    # --- face → core commands
    def handle(self, cmd):
        c = cmd.get("cmd")
        if c == "ack":
            path = cmd.get("path")
            for s in self.prev_sessions:
                if s["path"] == path:
                    self.acked[path] = ack_key(s)
        elif c == "pick_species":
            st = load_state()
            st["species"] = cmd.get("key")
            st["hatched"] = True
            st.pop("name", None)
            st.pop("form", None)  # evolution rollback belongs to the old species
            save_state(st)
        elif c == "set":
            key = cmd.get("key")
            if key in ("sound", "walk", "name", "species", "form",
                       "soundReady", "soundInput", "soundVolume"):
                st = load_state()
                st[key] = cmd.get("value")
                save_state(st)

    prev_sessions = []

    def serve(self):
        def reader():
            for line in sys.stdin:
                cmd = jload(line)
                if cmd:
                    try:
                        self.handle(cmd)
                    except Exception as e:  # a bad command must not kill the core
                        log(f"cmd error: {e}")
        threading.Thread(target=reader, daemon=True).start()
        while True:
            try:
                snap = self.poll()
                self.prev_sessions = snap["sessions"]
                self.emit(snap)
            except BrokenPipeError:
                return  # face died — exit with it
            except Exception as e:  # scanning must never crash the daemon
                log(f"poll error: {e}")
            time.sleep(1.0)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--serve"
    core = Core()
    if mode == "--once":
        snap = core.poll()
        # the first pass had no session list to match processes against
        refresh_open_sessions(snap["sessions"])
        snap = core.poll()
        json.dump(snap, sys.stdout, indent=2)
        print()
        return
    core.serve()


if __name__ == "__main__":
    main()
