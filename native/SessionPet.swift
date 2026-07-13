// SessionPet — native desktop pixel-art pet for coding agents (Claude Code + Codex).
//
// Port of pet_window.py with the same .state/state.json and native/assets.json
// (exported from the Python sprite maps — run native/export_assets.py after
// editing sprites). Native wins over tkinter: true per-pixel transparency with
// the WHOLE window clickable, retina-crisp sprites, lower footprint.
//
// Build:  swiftc -O native/SessionPet.swift -o native/SessionPet
// Run:    native/SessionPet [scale]     (default 5)

import AppKit
import Foundation

// MARK: - paths & constants

let home = FileManager.default.homeDirectoryForCurrentUser.path
// test override: point both providers at a fake home (fixtures) if set
let petHome = ProcessInfo.processInfo.environment["SESSION_PET_HOME"] ?? home
let petLogEnabled = ProcessInfo.processInfo.environment["SESSION_PET_LOG"] == "1"
// repo root = parent of the directory containing this binary (native/) —
// works wherever the repo is cloned, and whether invoked by absolute or
// relative path (argv[0] is cwd-relative for `./native/SessionPet`)
let exeArg = CommandLine.arguments[0]
let exeAbs = exeArg.hasPrefix("/") ? exeArg
    : FileManager.default.currentDirectoryPath + "/" + exeArg
let exePath = (exeAbs as NSString).resolvingSymlinksInPath
let petRoot = ((exePath as NSString).deletingLastPathComponent as NSString)
    .deletingLastPathComponent
let statePath = "\(petRoot)/.state/state.json"
let eventsPath = "\(petRoot)/.state/events.jsonl"
let assetsPath = "\(petRoot)/native/assets.json"

let workingWithin = 15.0, waitingWithin = 300.0, busyGrace = 300.0
let recentWindow = 3600.0, soundDebounce = 8.0
let inputTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
let stages: [(Int, String)] = [(0, "egg"), (30, "hatchling"), (200, "adult"), (1000, "legendary")]
let stageNext = ["egg": "hatchling", "hatchling": "adult", "adult": "legendary"]

let cBG = NSColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
let cFG = NSColor(red: 0.80, green: 0.84, blue: 0.96, alpha: 1)
let cMuted = NSColor(red: 0.50, green: 0.52, blue: 0.61, alpha: 1)
let cAccent = NSColor(red: 0.65, green: 0.89, blue: 0.63, alpha: 1)
let cWarn = NSColor(red: 1.00, green: 0.82, blue: 0.40, alpha: 1)
let cInput = NSColor(red: 0.95, green: 0.55, blue: 0.66, alpha: 1)
let cStalled = NSColor(red: 0.83, green: 0.64, blue: 0.45, alpha: 1) // desaturated amber

func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func petLog(_ msg: String) {
    guard petLogEnabled else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = Data("\(stamp) \(msg)\n".utf8)
    let logPath = "/tmp/session-pet.log"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: line)
    } else {
        try? line.write(to: URL(fileURLWithPath: logPath))
    }
}

func hexColor(_ hex: String) -> NSColor {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .white }
    return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

// stable per-project badge color, hashed from the project name (djb2)
func projectColor(_ name: String) -> NSColor {
    var h: UInt32 = 5381
    for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
    return NSColor(hue: CGFloat(h % 360) / 360.0, saturation: 0.55,
                   brightness: 0.88, alpha: 1)
}

// MARK: - assets

struct Species {
    let key: String, name: String, emoji: String
    let palette: [String: NSColor], rows: [String]
}

func loadAssets() -> (order: [String], species: [String: Species]) {
    guard let data = FileManager.default.contents(atPath: assetsPath),
          let root = json(data),
          let order = root["order"] as? [String],
          let dict = root["species"] as? [String: [String: Any]] else {
        fatalError("cannot load \(assetsPath) — run native/export_assets.py")
    }
    var out: [String: Species] = [:]
    for (key, s) in dict {
        var pal: [String: NSColor] = [:]
        for (ch, hex) in (s["palette"] as? [String: String]) ?? [:] { pal[ch] = hexColor(hex) }
        out[key] = Species(key: key, name: s["name"] as? String ?? key,
                           emoji: s["emoji"] as? String ?? "",
                           palette: pal, rows: s["rows"] as? [String] ?? [])
    }
    return (order, out)
}

let assets = loadAssets()

// MARK: - shared state (same file as the Python pet)

func loadState() -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: statePath) else { return [:] }
    if let parsed = json(d) { return parsed }
    // corrupt but non-empty: keep one .bak so the XP history is recoverable
    // instead of silently starting over
    if !d.isEmpty {
        let bak = statePath + ".bak"
        if !FileManager.default.fileExists(atPath: bak) {
            try? d.write(to: URL(fileURLWithPath: bak))
        }
    }
    return [:]
}

func saveState(_ state: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: state) else { return }
    let dir = (statePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic)
}

func totalXP(_ state: [String: Any]) -> Int {
    // pet.py prunes old per-session XP into banked_xp — count both
    let banked = (state["banked_xp"] as? NSNumber)?.intValue ?? 0
    return banked + ((state["sessions"] as? [String: Any]) ?? [:]).values
        .compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
}

func stageFor(_ xp: Int) -> (String, Int, Int?) {
    var stage = "egg", lo = 0; var hi: Int? = nil
    for (i, (threshold, name)) in stages.enumerated() where xp >= threshold {
        stage = name; lo = threshold
        hi = i + 1 < stages.count ? stages[i + 1].0 : nil
    }
    return (stage, lo, hi)
}

// MARK: - session scanning (ported from pet_window.py)

struct SessionInfo {
    var path: String, age: Double, phase: String, doing: String, provider: String
    var ctx: Int? = nil       // ≈ current context/input tokens
    var snippet: String = ""  // last agent message, for finished sessions
    var label: String = ""    // session title (ai-title) or start directory
    var cwd: String? = nil    // working dir of the session (may be tildified, display-only)
    var project: String = ""  // badge text = last path component of cwd
}

struct TailInfo {
    var stop: String? = nil, tool: String? = nil, detail = ""
    var ctx: Int? = nil, snippet = ""
    var title: String? = nil, cwd: String? = nil
    var newTurn = false  // a real user prompt arrived AFTER the last end_turn
    var hookContinuation = false  // Stop-hook feedback arrived AFTER end_turn
}

func tildify(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func ackKey(_ s: SessionInfo) -> String {
    // snippet alone is often "" (input/stalled turns); ctx grows every turn,
    // so together they identify a turn without depending on volatile mtime
    "\(s.snippet)|\(s.ctx ?? 0)"
}

func fmtTokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1000 ? "\(n / 1000)k" : "\(n)"
}

func tailLines(_ path: String, want: UInt64 = 65536) -> [String] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let start = size > want ? size - want : 0
    try? fh.seek(toOffset: start)
    guard let data = try? fh.readToEnd() else { return [] }
    // lossy decode — a stray invalid byte must never nil the whole tail
    var lines = String(decoding: data, as: UTF8.self)
        .split(separator: "\n").map(String.init)
    // the first line of a mid-file chunk is almost certainly partial
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
}

func snippetOf(_ s: String) -> String {
    String(s.split(separator: "\n").first ?? "").prefix(64).description
}

// normalized: stop ∈ end_turn | tool_use | pending | writing | nil
func tailInfoClaude(_ path: String) -> TailInfo {
    var info = parseClaudeTail(tailLines(path))
    if info.stop == nil {
        // no decisive assistant event in the last 64KB (huge tool_results) —
        // grow the backwards read once
        info = parseClaudeTail(tailLines(path, want: 524_288))
    }
    return info
}

func parseClaudeTail(_ lines: [String]) -> TailInfo {
    var info = TailInfo()
    var decided = false
    for line in lines.reversed() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        guard let ev = json(Data(t.utf8)) else {
            if !decided { info.stop = "writing"; decided = true }
            continue
        }
        let type = ev["type"] as? String
        if info.cwd == nil, let cwd = ev["cwd"] as? String { info.cwd = cwd }
        if info.title == nil, type == "ai-title" { info.title = ev["aiTitle"] as? String }
        if decided {
            if info.title != nil && info.cwd != nil { break }
            continue
        }
        if type == "user", !info.hookContinuation {
            // hook-feedback events are isMeta, but they are THE signal that a
            // blocking Stop hook is continuing the turn — an end_turn followed
            // by one is intermediate, not final (Lori's memory checkpoint
            // blocks every turn once, and the continuation can outlast any
            // fixed ready-hold when it calls MCP tools)
            let c = (ev["message"] as? [String: Any])?["content"]
            if let s = c as? String, s.hasPrefix("Stop hook feedback") {
                info.hookContinuation = true
            }
        }
        if type == "user", !info.newTurn, ev["isMeta"] as? Bool != true {
            // a REAL prompt (string content / text blocks, not a tool_result)
            // newer than the last assistant event = a new turn is starting,
            // even though Claude hasn't written its first event yet (thinking)
            let content = (ev["message"] as? [String: Any])?["content"]
            if let s = content as? String {
                // local-command echoes and interruption markers are meta,
                // not real prompts
                if !s.hasPrefix("<local-command") && !s.hasPrefix("[Request interrupted") {
                    info.newTurn = true
                }
            } else if let blocks = content as? [[String: Any]],
                      !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                info.newTurn = true
            }
        }
        if type == "assistant" {
            let msg = ev["message"] as? [String: Any] ?? [:]
            info.stop = msg["stop_reason"] as? String
            if let usage = msg["usage"] as? [String: Any] {
                // input + cache reads ≈ the session's live context size
                info.ctx = ["input_tokens", "cache_read_input_tokens",
                            "cache_creation_input_tokens"]
                    .compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
            }
            for block in (msg["content"] as? [[String: Any]] ?? []).reversed() {
                if block["type"] as? String == "tool_use", info.tool == nil {
                    let inp = block["input"] as? [String: Any] ?? [:]
                    let detail = (inp["description"] ?? inp["command"] ?? inp["file_path"]
                                  ?? inp["pattern"] ?? "") as? String ?? ""
                    info.tool = block["name"] as? String
                    info.detail = String(detail.split(separator: "\n").first ?? "")
                        .prefix(44).description
                }
                if block["type"] as? String == "text", info.snippet.isEmpty {
                    info.snippet = snippetOf(block["text"] as? String ?? "")
                }
            }
            decided = true // keep scanning only for title/cwd
            continue
        }
        // anything else — tool_results, stop-hook feedback (user events),
        // housekeeping (queue-operation, mode, …) — is skipped: only the
        // newest ASSISTANT event tells the truth about the session
    }
    return info
}

// exec commands arrive either as one string or as an argv array of strings
func cmdString(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let a = v as? [String] { return a.joined(separator: " ") }
    return ""
}

func tailInfoCodex(_ path: String) -> TailInfo {
    var info = parseCodexTail(tailLines(path))
    if info.stop == nil {
        info = parseCodexTail(tailLines(path, want: 524_288))
    }
    return info
}

func parseCodexTail(_ lines: [String]) -> TailInfo {
    var info = TailInfo()
    var decided = false
    var scanned = 0
    for line in lines.reversed() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        scanned += 1
        // keep scanning a bit past the decisive event to also pick up
        // token_count (written just before task_complete)
        if scanned > 40 || (decided && info.ctx != nil) { break }
        guard let ev = json(Data(t.utf8)) else {
            if !decided { info.stop = "writing"; decided = true }
            continue
        }
        let p = ev["payload"] as? [String: Any] ?? [:]
        let pt = p["type"] as? String
        if ev["type"] as? String == "event_msg", pt == "token_count", info.ctx == nil {
            let usage = (p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any]
            info.ctx = ["input_tokens"]
                .compactMap { (usage?[$0] as? NSNumber)?.intValue }.reduce(0, +)
            continue
        }
        if decided { continue }
        switch ev["type"] as? String {
        case "event_msg":
            switch pt {
            case "task_complete":
                info.stop = "end_turn"
                info.snippet = snippetOf(p["last_agent_message"] as? String ?? "")
                decided = true
            case "request_user_input", "elicitation_request":
                info.stop = "tool_use"; info.tool = "AskUserQuestion"
                info.detail = "question for you"; decided = true
            case "exec_command_begin":
                info.stop = "tool_use"; info.tool = "shell"
                info.detail = String(cmdString(p["command"]).prefix(44)); decided = true
            case "task_started":
                info.stop = "pending"; decided = true
            case "user_message":
                info.stop = "pending"; decided = true
            default: continue
            }
        case "response_item":
            switch pt {
            case "function_call":
                info.stop = "tool_use"; info.tool = p["name"] as? String ?? "tool"
                info.detail = String((p["arguments"] as? String ?? "").prefix(44)); decided = true
            case "local_shell_call":
                let cmd = cmdString((p["action"] as? [String: Any])?["command"])
                info.stop = "tool_use"; info.tool = "shell"
                info.detail = String(cmd.prefix(44)); decided = true
            case "message", "function_call_output":
                info.stop = "pending"; decided = true
            default: continue
            }
        default: continue
        }
    }
    return info
}

func claudeTranscripts() -> [String] {
    let base = "\(petHome)/.claude/projects"
    let fm = FileManager.default
    var out: [String] = []
    for dir in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
        let d = "\(base)/\(dir)"
        for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".jsonl") {
            out.append("\(d)/\(f)")
        }
    }
    return out
}

func codexTranscripts() -> [String] {
    // rollouts live at sessions/YYYY/MM/DD/rollout-*.jsonl — scan today plus a
    // few older day-dirs: multi-day sessions keep appending to the file in the
    // dir where they STARTED
    let fm = FileManager.default
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.calendar = Calendar(identifier: .gregorian)
    fmt.dateFormat = "yyyy/MM/dd"
    var out: [String] = []
    for delta in [0.0, -86400.0, -172_800.0, -259_200.0] {
        let d = "\(petHome)/.codex/sessions/\(fmt.string(from: Date(timeIntervalSinceNow: delta)))"
        for f in (try? fm.contentsOfDirectory(atPath: d)) ?? []
        where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
            out.append("\(d)/\(f)")
        }
    }
    return out
}

func projectLabel(_ path: String, _ provider: String) -> String {
    if provider == "codex" {
        // cwd lives in the session_meta first line
        if let fh = FileHandle(forReadingAtPath: path),
           let head = try? fh.read(upToCount: 4096),
           let text = String(data: head, encoding: .utf8),
           let first = text.split(separator: "\n").first,
           let ev = json(Data(first.utf8)),
           let cwd = (ev["payload"] as? [String: Any])?["cwd"] as? String {
            try? fh.close()
            return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        }
        return "codex"
    }
    var label = (path as NSString).deletingLastPathComponent
    label = (label as NSString).lastPathComponent
    let homeKey = "-" + home.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: "-") + "-"
    if label.hasPrefix(homeKey) { label = "~/" + label.dropFirst(homeKey.count) }
    return label
}

var stopCache: [String: (Double, TailInfo)] = [:]

// A Claude end_turn is NOT always the end of the turn: Stop hooks (Lori's
// memory checkpoint blocks every turn once) and queued messages continue the
// conversation seconds later — 33 such intermediate end_turns were counted in
// a single session. hookContinuation/newTurn detect those precisely once the
// follow-up event is written; this hold only covers the 1-3s write gap.
let readyConfirm = 4.0
var readyHold: [String: (String, Double)] = [:]  // path → (turn key, first seen)

func fmtAge(_ age: Double) -> String {
    if age < 60 { return "\(Int(age))s" }
    if age < 3600 { return "\(Int(age / 60))m" }
    return "\(Int(age / 3600))h"
}

func scanSessions() -> [SessionInfo] {
    let now = Date().timeIntervalSince1970
    let fm = FileManager.default
    var out: [SessionInfo] = []
    let sources: [(String, [String], (String) -> TailInfo)] =
        [("claude", claudeTranscripts(), tailInfoClaude),
         ("codex", codexTranscripts(), tailInfoCodex)]
    for (provider, paths, tailer) in sources {
        for path in paths {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mdate = attrs[.modificationDate] as? Date else { continue }
            let mtime = mdate.timeIntervalSince1970
            let age = now - mtime
            if age > recentWindow { continue }
            let info: TailInfo
            if let cached = stopCache[path], cached.0 == mtime {
                info = cached.1
            } else {
                info = tailer(path)
                stopCache[path] = (mtime, info)
            }
            var phase = "", doing = ""
            if info.stop == "tool_use", let tool = info.tool, inputTools.contains(tool), age > 3 {
                phase = "input"; doing = "needs your answer"
            } else if info.stop == "end_turn" || info.stop == "stop_sequence" {
                if info.hookContinuation && age < busyGrace {
                    // a blocking Stop hook is continuing the turn (memory
                    // checkpoint) — this end_turn is intermediate, no ding
                    phase = "working"; doing = "running stop hooks…"
                } else if info.newTurn && age < busyGrace {
                    // prompt submitted, Claude thinking — no assistant event yet
                    phase = "working"; doing = "processing your prompt…"
                } else if age < waitingWithin {
                    // end_turn is authoritative even at fresh mtime —
                    // housekeeping events keep touching the file after a turn
                    phase = "ready"; doing = "finished — waiting for you"
                    if provider == "claude" {
                        // …but a Claude end_turn may be a stop-hook/queued-msg
                        // intermediate: hold "ready" until it survives
                        // readyConfirm seconds with no newer assistant event
                        let key = "\(info.snippet)|\(info.ctx ?? 0)"
                        if readyHold[path]?.0 != key { readyHold[path] = (key, now) }
                        if now - readyHold[path]!.1 < readyConfirm, age < readyConfirm + 30 {
                            phase = "working"; doing = "finishing up…"
                        }
                    }
                } else { phase = "idle"; doing = "done" }
            } else if age < workingWithin {
                phase = "working"
                doing = info.stop == "tool_use" && info.tool != nil
                    ? "\(info.tool!)\(info.detail.isEmpty ? "" : " · " + info.detail)"
                    : "thinking / writing"
            } else if age < busyGrace {
                phase = "busy"
                doing = info.tool != nil
                    ? "\(info.tool!) · still running" : "still running"
            } else if info.stop == "tool_use" || info.stop == "pending"
                        || info.stop == "writing" {
                // blocked mid-turn (permission prompt, hung tool, crash) —
                // keep it visible instead of vanishing; also preserves
                // prevPhases continuity so a late end_turn still dings
                // (age >= busyGrace here; age <= recentWindow filtered above)
                phase = "stalled"
                doing = "no output — may need you"
            } else { continue }
            var dispAge = age
            if provider == "claude" {
                // subagents (workflows, Agent tool) write transcripts under
                // <session-id>/subagents/** — while they run, the parent
                // session's own transcript is idle but the SESSION is not
                let subDir = String(path.dropLast(6)) + "/subagents"
                var active = 0
                var newestSub = Double.infinity
                if let en = fm.enumerator(atPath: subDir) {
                    for case let f as String in en where f.hasSuffix(".jsonl") {
                        if let a = try? fm.attributesOfItem(atPath: "\(subDir)/\(f)"),
                           let d = a[.modificationDate] as? Date {
                            let sage = now - d.timeIntervalSince1970
                            newestSub = min(newestSub, sage)
                            if sage < workingWithin { active += 1 }
                        }
                    }
                }
                if active > 0, phase != "input" {
                    phase = "working"
                    doing = "\(active) subagent\(active == 1 ? "" : "s") working…"
                    dispAge = min(dispAge, newestSub)
                }
            }
            // cwd: real event cwd when present, else the decoded projectLabel
            // path (display-only — may be tildified); project badge = its last
            // path component, hard-capped at 14 chars
            let fallback = projectLabel(path, provider)
            let cwd = info.cwd
                ?? ((fallback.hasPrefix("~") || fallback.hasPrefix("/")) ? fallback : nil)
            var project = ((cwd ?? fallback) as NSString).lastPathComponent
            if project.count > 14 { project = String(project.prefix(14)) }
            if project.isEmpty || project == "~" { project = provider }
            let label = info.title ?? info.cwd.map(tildify) ?? fallback
            out.append(SessionInfo(path: path, age: dispAge, phase: phase, doing: doing,
                                   provider: provider, ctx: info.ctx,
                                   snippet: info.snippet, label: label,
                                   cwd: cwd, project: project))
        }
    }
    return out.sorted { $0.age < $1.age }
}

// MARK: - sprite rendering

func drawSprite(_ key: String, scale: CGFloat, at origin: NSPoint, eyesClosed: Bool) {
    guard let sp = assets.species[key] else { return }
    let rowCount = sp.rows.count
    for (y, row) in sp.rows.enumerated() {
        for (x, ch) in row.enumerated() {
            var c = String(ch)
            if c == "." { continue }
            if eyesClosed && (c == "o" || c == "w") { c = "X" }
            guard let color = sp.palette[c] else { continue }
            color.setFill()
            // flip y: pixel row 0 is the TOP of the sprite
            NSRect(x: origin.x + CGFloat(x) * scale,
                   y: origin.y + CGFloat(rowCount - 1 - y) * scale,
                   width: scale, height: scale).fill()
        }
    }
}

func spriteImage(_ key: String, scale: CGFloat) -> NSImage {
    guard let sp = assets.species[key] else { return NSImage() }
    let w = CGFloat(sp.rows.first?.count ?? 16) * scale
    let h = CGFloat(sp.rows.count) * scale
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    drawSprite(key, scale: scale, at: .zero, eyesClosed: false)
    img.unlockFocus()
    return img
}

// MARK: - pet view + window

final class PetView: NSView {
    var scale: CGFloat = 5
    var frameCount = 0
    var mode = "waiting"
    var sessions: [SessionInfo] = []
    var state: [String: Any] = loadState()
    var alertUntil = 0.0
    var needsAttention = false // any unacked ready/input/stalled session
    var onClick: (() -> Void)?
    var onToggleSound: (() -> Void)?
    private var dragOffset: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        let w = window!.frame.origin
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - w.x, y: m.y - w.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let off = dragOffset, let win = window else { return }
        let m = NSEvent.mouseLocation
        let target = NSPoint(x: m.x - off.x, y: m.y - off.y)
        if abs(target.x - win.frame.origin.x) + abs(target.y - win.frame.origin.y) > 3 {
            dragged = true
        }
        win.setFrameOrigin(target)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
    }

    override func rightMouseUp(with event: NSEvent) {
        // small menu instead of instant quit — a stray right-click used to
        // kill the pet
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open panel", action: #selector(menuOpenPanel(_:)),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let sound = NSMenuItem(title: "Sound", action: #selector(menuToggleSound(_:)),
                               keyEquivalent: "")
        sound.target = self
        sound.state = (state["sound"] as? Bool ?? true) ? .on : .off
        menu.addItem(sound)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit pet",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuOpenPanel(_ sender: Any?) { onClick?() }
    @objc private func menuToggleSound(_ sender: Any?) { onToggleSound?() }

    override func draw(_ dirtyRect: NSRect) {
        let s = scale
        let cols = bounds.width / s
        let xp = totalXP(state)
        var (stage, _, _) = stageFor(xp)
        let hatched = (state["hatched"] as? Bool ?? false) || stage != "egg"
        if hatched && stage == "egg" { stage = "hatchling" }
        let speciesKey = state["species"] as? String ?? "cat"
        let spriteKey = hatched ? speciesKey : "egg"
        let sp = assets.species[spriteKey] ?? assets.species["cat"]!

        let bobPeriod = mode == "working" ? 2 : (mode == "waiting" ? 6 : 10)
        let bob = CGFloat((frameCount / bobPeriod) % 2) * (s / 2)
        let spriteW = CGFloat(sp.rows.first?.count ?? 16) * s
        let ox = (bounds.width - spriteW) / 2
        let baseY = 3.5 * s // above caption + dots

        // ground shadow
        NSColor(white: 0, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width / 2 - 7 * s, y: baseY - 0.8 * s,
                                    width: 14 * s, height: 1.6 * s)).fill()

        let blink = mode == "sleeping" || frameCount % 16 == 0
        drawSprite(spriteKey, scale: s, at: NSPoint(x: ox, y: baseY + bob), eyesClosed: blink)

        // effects
        let effFont = NSFont(name: "Menlo-Bold", size: s + 6) ?? .systemFont(ofSize: s + 6)
        func puts(_ text: String, _ x: CGFloat, _ y: CGFloat, _ color: NSColor, _ f: NSFont? = nil) {
            (text as NSString).draw(at: NSPoint(x: x, y: y),
                                    withAttributes: [.font: f ?? effFont, .foregroundColor: color])
        }
        let topY = baseY + CGFloat(sp.rows.count) * s
        if Date().timeIntervalSince1970 < alertUntil || needsAttention {
            // persistent while ANY unacknowledged session waits on you —
            // not just for 5s after the ding
            puts("!", bounds.width - 3 * s, topY - s, cWarn)
        } else if mode == "working" {
            for i in 0..<3 {
                let px = CGFloat((frameCount * 3 + i * 41) % Int(max(1, (cols - 1) * s)))
                let py = topY - CGFloat((frameCount * 5 + i * 29) % Int(3 * s))
                puts("✦", px, py, cWarn, NSFont(name: "Menlo", size: s + 2))
            }
        } else if mode == "waiting" {
            puts("?", bounds.width - 3 * s, topY - s, cWarn)
        } else {
            for i in 0..<3 {
                let phase = CGFloat(((frameCount / 2) + i * 3) % 9)
                puts("z", bounds.width / 2 + 3 * s + phase * 2, topY - 2 * s + phase * s / 2,
                     cMuted, NSFont(name: "Menlo", size: s + 2 + CGFloat(i)))
            }
        }

        // per-session dots (only when juggling several live sessions)
        let live = sessions.filter { $0.phase != "idle" }
        if live.count > 1 {
            let dots = live.prefix(8)
            let gap = 2 * s, r = s * 0.4
            var x = bounds.width / 2 - gap * CGFloat(dots.count - 1) / 2
            for sess in dots {
                // shape doubles the color (colorblind dual-coding):
                // filled circle = working, square = ready, ring = needs a human
                let rect = NSRect(x: x - r, y: 2.4 * s - r, width: 2 * r, height: 2 * r)
                switch sess.phase {
                case "ready":
                    cWarn.setFill()
                    rect.fill()
                case "input", "stalled":
                    let c = sess.phase == "input" ? cInput : cStalled
                    c.withAlphaComponent(frameCount % 2 == 0 ? 1 : 0.35).setStroke()
                    let lw = max(1, s * 0.25)
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: lw / 2, dy: lw / 2))
                    ring.lineWidth = lw
                    ring.stroke()
                default: // working / busy
                    cAccent.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
                x += gap
            }
        }

        // outlined caption — readable over any background
        let level = min(99, 1 + Int((Double(xp) / 10.0).squareRoot()))
        let name = hatched ? (state["name"] as? String ?? sp.name) : "???"
        let crown = stage == "legendary" ? "👑" : ""
        let caption = "\(crown)\(name) · Lv.\(level)" as NSString
        let capFont = NSFont(name: "Menlo-Bold", size: s + 6) ?? .boldSystemFont(ofSize: s + 6)
        let attrs: [NSAttributedString.Key: Any] = [.font: capFont, .foregroundColor: cFG]
        let sz = caption.size(withAttributes: attrs)
        // name plate: rounded dark pill keeps the caption readable on ANY
        // background (stroked text looked ragged over white windows)
        let pad: CGFloat = 6
        let plate = NSRect(x: (bounds.width - sz.width) / 2 - pad, y: 0.2 * s - 2,
                           width: sz.width + 2 * pad, height: sz.height + 4)
        NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        caption.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: 0.2 * s),
                     withAttributes: attrs)
    }
}

// MARK: - details panel

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true } // content starts at the TOP
}

class FlippedView: NSView {
    override var isFlipped: Bool { true } // manual top-down card layout
}

class ClickableCard: FlippedView {
    var onClick: (() -> Void)?
    private var downAt: NSPoint = .zero
    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation }
    override func mouseUp(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if abs(m.x - downAt.x) + abs(m.y - downAt.y) < 6 { onClick?() }
    }
}

// one PERSISTENT expandable card per session (code-island style): the surface
// itself encodes state (phase-tinted fill + 1px phase border). v2 layout:
// identity strip (project badge + age) → wrapping 2-line title (hero, neutral,
// SF Semibold) → phase-colored status. Expanded shows the cwd path (never the
// transcript UUID), provider/ctx meta, and the last snippet. Labels update in
// place so a refresh never destroys the view mid-click.
final class SessionCard: ClickableCard {
    private let badge = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        // Menlo only for identifiers: badge, age, path, token counts
        badge.font = NSFont(name: "Menlo-Bold", size: 10)
        badge.alignment = .center
        badge.lineBreakMode = .byClipping
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        ageLabel.font = NSFont(name: "Menlo", size: 10)
        ageLabel.textColor = cMuted
        ageLabel.alignment = .right
        // SF Pro for prose: title is the hero, wraps to 2 full-width lines
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = cFG
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        status.font = NSFont.systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        pathLabel.font = NSFont(name: "Menlo", size: 10)
        pathLabel.textColor = cMuted
        pathLabel.lineBreakMode = .byTruncatingMiddle
        meta.font = NSFont(name: "Menlo", size: 10)
        meta.textColor = cMuted
        meta.lineBreakMode = .byTruncatingTail
        snippet.font = NSFont.systemFont(ofSize: 11)
        snippet.textColor = cFG
        snippet.maximumNumberOfLines = 3
        snippet.cell?.truncatesLastVisibleLine = true
        for l in [badge, ageLabel, titleLabel, status, pathLabel, meta, snippet] {
            l.isSelectable = false // selectable labels swallow the card's click
            addSubview(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // update every label/color/frame in place and resize the card
    func update(_ sess: SessionInfo, open: Bool, width: CGFloat) {
        let padH: CGFloat = 12, padV: CGFloat = 10
        let W = width - 2 * padH
        let color = ["working": cAccent, "busy": cAccent, "input": cInput,
                     "ready": cWarn, "stalled": cStalled][sess.phase] ?? cMuted
        let idle = sess.phase == "idle"
        layer?.backgroundColor = color.withAlphaComponent(idle ? 0.04 : 0.07).cgColor
        layer?.borderColor = color.withAlphaComponent(
            sess.phase == "input" ? 0.45 : (idle ? 0.15 : 0.35)).cgColor

        // row 1 — identity strip (h 16): project badge left, one age top-right;
        // badge hides when the title itself is the path (no duplication)
        var cy = padV
        let cwdDisp = sess.cwd.map(tildify)
        let hideBadge = sess.project.isEmpty || sess.label == cwdDisp
        badge.isHidden = hideBadge
        if !hideBadge {
            badge.stringValue = sess.project
            let pc = projectColor(sess.project)
            badge.textColor = pc
            badge.layer?.backgroundColor = pc.withAlphaComponent(0.16).cgColor
            let bw = min(badge.attributedStringValue.size().width + 12, 120)
            badge.frame = NSRect(x: padH, y: cy, width: bw, height: 16)
        }
        ageLabel.stringValue = fmtAge(sess.age)
        ageLabel.frame = NSRect(x: width - padH - 48, y: cy + 2, width: 48, height: 13)
        cy += 22

        // row 2 — title (hero), wraps to at most 2 full-width lines
        titleLabel.stringValue = sess.label
        let th = NSAttributedString(string: sess.label, attributes:
            [.font: titleLabel.font!]).boundingRect(
                with: NSSize(width: W, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]).height
        titleLabel.frame = NSRect(x: padH, y: cy, width: W, height: min(ceil(th) + 1, 36))
        cy += titleLabel.frame.height + 4

        // row 3 — status, the only phase-colored text
        status.stringValue = sess.doing
        status.textColor = idle ? cMuted : color
        status.frame = NSRect(x: padH, y: cy, width: W, height: 15)
        cy += 15

        pathLabel.isHidden = !open || cwdDisp == nil
        meta.isHidden = !open
        snippet.isHidden = !open || sess.snippet.isEmpty
        if open {
            cy += 6
            if let p = cwdDisp {
                pathLabel.stringValue = p
                pathLabel.frame = NSRect(x: padH, y: cy, width: W, height: 13)
                cy += 15
            }
            var m: [String] = [sess.provider]
            if let ctx = sess.ctx { m.append("ctx \(fmtTokens(ctx))") }
            meta.stringValue = m.joined(separator: " · ")
            meta.frame = NSRect(x: padH, y: cy, width: W, height: 13)
            cy += 15
            if !sess.snippet.isEmpty {
                snippet.stringValue = "“\(sess.snippet)”"
                let sh = snippet.attributedStringValue.boundingRect(
                    with: NSSize(width: W, height: 48),
                    options: [.usesLineFragmentOrigin]).height
                snippet.frame = NSRect(x: padH, y: cy, width: W,
                                       height: min(ceil(sh) + 2, 48))
                cy += snippet.frame.height + 2
            }
        }
        setFrameSize(NSSize(width: width, height: cy + padV))
    }
}

final class Panel {
    let panel: NSPanel
    let title = NSTextField(labelWithString: "")
    let xpLabel = NSTextField(labelWithString: "") // stage · XP · next, one line
    let chipsRow = NSStackView() // colored per-state count pills
    let bar = NSView(), barFill = NSView()
    let sessionDoc = FlippedView()
    let sessionScroll = NSScrollView()
    var sessionHeight: NSLayoutConstraint!
    var expanded: Set<String> = []  // session card expansion state, by path
    var cards: [String: SessionCard] = [:]  // persistent card per session path
    private var emptyLabel: NSTextField?
    var onCardClick: ((SessionInfo) -> Void)?
    private var lastRefresh: ([String: Any], String, [SessionInfo], Int)?
    let soundCheck = NSButton(checkboxWithTitle: "sound when an agent needs me",
                              target: nil, action: nil)
    let settingsBox = NSStackView()
    let settingsToggle = NSButton(title: "settings ▸", target: nil, action: nil)
    var pickButtons: [String: NSButton] = [:]
    var onPick: ((String) -> Void)?
    var onSound: ((Bool) -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = cBG.cgColor
        card.layer?.cornerRadius = 12

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        title.font = NSFont(name: "Menlo-Bold", size: 15)
        title.textColor = cFG
        xpLabel.font = NSFont(name: "Menlo", size: 11)
        xpLabel.textColor = cMuted
        chipsRow.orientation = .horizontal
        chipsRow.spacing = 6

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        bar.layer?.cornerRadius = 3
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 332).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = cAccent.cgColor
        barFill.layer?.cornerRadius = 3
        bar.addSubview(barFill)

        // session cards scroll inside a capped height (code-island style);
        // manual frames on a flipped document view — autolayout documentViews
        // silently collapse to zero height and never scroll
        let clip = FlippedClipView()
        clip.drawsBackground = false
        sessionScroll.contentView = clip
        sessionScroll.documentView = sessionDoc
        sessionScroll.hasVerticalScroller = true
        sessionScroll.autohidesScrollers = true
        sessionScroll.drawsBackground = false
        sessionScroll.verticalScrollElasticity = .allowed
        sessionScroll.translatesAutoresizingMaskIntoConstraints = false
        sessionHeight = sessionScroll.heightAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            sessionScroll.widthAnchor.constraint(equalToConstant: 332),
            sessionHeight,
        ])

        // species picker grid (always visible — native panel has the room)
        let grid = NSStackView(); grid.orientation = .vertical; grid.spacing = 4
        var row: NSStackView? = nil
        for (i, key) in assets.order.enumerated() {
            if i % 4 == 0 { row = NSStackView(); row!.spacing = 4; grid.addArrangedSubview(row!) }
            let b = NSButton(image: spriteImage(key, scale: 2), target: nil, action: nil)
            b.bezelStyle = .regularSquare
            b.isBordered = true
            b.setButtonType(.momentaryPushIn)
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.target = self
            b.action = #selector(pick(_:))
            pickButtons[key] = b
            row!.addArrangedSubview(b)
        }

        soundCheck.attributedTitle = Panel.buttonTitle("sound when an agent needs me")
        soundCheck.target = self
        soundCheck.action = #selector(soundToggled(_:))

        let quit = NSButton(title: "quit pet", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.font = NSFont(name: "Menlo", size: 10)

        // info first — picker + sound live behind a collapsed settings toggle
        settingsBox.orientation = .vertical
        settingsBox.alignment = .leading
        settingsBox.spacing = 6
        settingsBox.addArrangedSubview(grid)
        settingsBox.addArrangedSubview(soundCheck)
        settingsBox.addArrangedSubview(quit)
        settingsBox.isHidden = true
        settingsToggle.isBordered = false
        settingsToggle.attributedTitle = Panel.buttonTitle("settings ▸")
        settingsToggle.target = self
        settingsToggle.action = #selector(toggleSettings(_:))

        for v2 in [title, xpLabel, bar, sep(), chipsRow, sessionScroll,
                   sep(), settingsToggle, settingsBox] {
            stack.addArrangedSubview(v2)
        }
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        panel.contentView = card
    }

    private func sep() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.widthAnchor.constraint(equalToConstant: 332).isActive = true
        return v
    }

    static func buttonTitle(_ s: String) -> NSAttributedString {
        // dark card + default button title color = invisible text; force light
        NSAttributedString(string: s, attributes: [
            .foregroundColor: cFG,
            .font: NSFont(name: "Menlo", size: 10) ?? NSFont.systemFont(ofSize: 10),
        ])
    }

    private func toggleCard(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        if let (st, m, se, n) = lastRefresh {
            refresh(state: st, mode: m, sessions: se, nInput: n)
        }
    }

    @objc private func toggleSettings(_ sender: NSButton) {
        settingsBox.isHidden.toggle()
        settingsToggle.attributedTitle =
            Panel.buttonTitle(settingsBox.isHidden ? "settings ▸" : "settings ▾")
        panel.setContentSize(panel.contentView!.fittingSize)
        fitOnScreen()
    }

    // keep the whole panel visible after any resize — growing must never push
    // it off-screen or over the Dock
    func fitOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var o = panel.frame.origin
        let vis = screen.visibleFrame
        o.y = max(vis.minY, min(o.y, vis.maxY - panel.frame.height))
        o.x = max(vis.minX, min(o.x, vis.maxX - panel.frame.width))
        panel.setFrameOrigin(o)
    }

    @objc private func pick(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { onPick?(key) }
    }

    @objc private func soundToggled(_ sender: NSButton) {
        onSound?(sender.state == .on)
    }

    func refresh(state: [String: Any], mode: String, sessions: [SessionInfo], nInput: Int) {
        lastRefresh = (state, mode, sessions, nInput)
        let xp = totalXP(state)
        var (stage, lo, hi) = stageFor(xp)
        let hatched = (state["hatched"] as? Bool ?? false) || stage != "egg"
        if hatched && stage == "egg" { stage = "hatchling"; lo = 0; hi = 200 }
        let speciesKey = state["species"] as? String ?? "cat"
        let sp = assets.species[speciesKey] ?? assets.species["cat"]!
        let level = min(99, 1 + Int((Double(xp) / 10.0).squareRoot()))
        let crown = stage == "legendary" ? "👑 " : ""
        let name = hatched ? (state["name"] as? String ?? sp.name) : "???"

        title.stringValue = "\(sp.emoji) \(crown)\(name) · Lv.\(level)"
        // stage merged into the xp line — no separate stage row
        if let hi = hi {
            xpLabel.stringValue = hatched
                ? "\(stage) · \(xp) XP · \(hi - xp) to \(stageNext[stage] ?? "?")"
                : "egg · pick a sprite in settings to hatch!"
            let frac = max(0, min(1, Double(xp - lo) / Double(hi - lo)))
            barFill.frame = NSRect(x: 0, y: 0, width: 332 * frac, height: 6)
        } else {
            xpLabel.stringValue = "\(stage) · \(xp) XP · max stage"
            barFill.frame = NSRect(x: 0, y: 0, width: 332, height: 6)
        }

        // colored count chips instead of a single status line
        chipsRow.arrangedSubviews.forEach {
            chipsRow.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        func chip(_ text: String, _ color: NSColor) {
            let l = NSTextField(labelWithString: "  \(text)  ")
            l.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            l.textColor = color
            l.wantsLayer = true
            l.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
            l.layer?.cornerRadius = 9
            l.heightAnchor.constraint(equalToConstant: 18).isActive = true
            chipsRow.addArrangedSubview(l)
        }
        let nWorking = sessions.filter { $0.phase == "working" || $0.phase == "busy" }.count
        let nNeed = sessions.filter { $0.phase == "input" }.count
        let nStalled = sessions.filter { $0.phase == "stalled" }.count
        let nDone = sessions.filter { $0.phase == "ready" }.count
        if nWorking > 0 { chip("\(nWorking) working", cAccent) }
        if nNeed > 0 { chip("\(nNeed) need you", cInput) }
        if nStalled > 0 { chip("\(nStalled) stalled", cStalled) }
        if nDone > 0 { chip("\(nDone) done", cWarn) }
        if chipsRow.arrangedSubviews.isEmpty { chip("all idle", cMuted) }

        // one persistent card per session path — labels update in place, so a
        // refresh never destroys a card mid-click and ages tick every refresh
        let ordered = sessions.sorted { ($0.phase == "idle" ? 1 : 0) < ($1.phase == "idle" ? 1 : 0) }
            .prefix(20)
        let livePaths = Set(ordered.map { $0.path })
        for (path, card) in cards where !livePaths.contains(path) {
            card.removeFromSuperview()
            cards.removeValue(forKey: path)
        }
        var y: CGFloat = 0
        for sess in ordered {
            let card: SessionCard
            if let existing = cards[sess.path] {
                card = existing
            } else {
                card = SessionCard()
                cards[sess.path] = card
                sessionDoc.addSubview(card)
            }
            card.update(sess, open: expanded.contains(sess.path), width: 324)
            card.setFrameOrigin(NSPoint(x: 0, y: y))
            card.onClick = { [weak self] in
                self?.onCardClick?(sess) // per-card ack
                self?.toggleCard(sess.path)
            }
            y += card.frame.height + 8
        }
        if ordered.isEmpty {
            if emptyLabel == nil {
                let l = NSTextField(labelWithString: "no recent sessions")
                l.font = NSFont.systemFont(ofSize: 11); l.textColor = cMuted
                l.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
                sessionDoc.addSubview(l)
                emptyLabel = l
            }
            y = 18
        }
        emptyLabel?.isHidden = !ordered.isEmpty
        sessionDoc.frame = NSRect(x: 0, y: 0, width: 332, height: max(y, 18))
        sessionHeight.constant = min(max(y, 18), 300)

        soundCheck.state = (state["sound"] as? Bool ?? true) ? .on : .off
        for (key, b) in pickButtons {
            b.layer?.borderWidth = key == speciesKey ? 2 : 0
            b.layer?.borderColor = cAccent.cgColor
        }
        panel.setContentSize(panel.contentView!.fittingSize)
        if panel.isVisible { fitOnScreen() }
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: PetView!
    var petPanel = Panel()
    var lastPoll = 0.0, lastSound = 0.0, lastPing = 0.0
    var evOffset: UInt64 = 0, evPrimed = false
    var notif: [String: (Double, String)] = [:]
    var prevPhases: [String: String] = [:]
    // path → snippet acked by clicking that session's card; keyed by snippet
    // (stable per turn) so post-turn housekeeping writes don't re-nag
    var acked: [String: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scale = CGFloat(min(12, max(3,
            CommandLine.arguments.dropFirst().compactMap { Int($0) }.first ?? 5)))
        let w = 18 * scale, h = 23 * scale
        view = PetView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.scale = scale
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - w - 30,
                                          y: screen.visibleFrame.minY + 40))
        }
        window.makeKeyAndOrderFront(nil)

        view.onClick = { [weak self] in self?.togglePanel() }
        petPanel.onPick = { [weak self] key in
            var st = loadState()
            st["species"] = key
            st["hatched"] = true
            st.removeValue(forKey: "name")
            saveState(st)
            self?.view.state = st
            self?.refreshPanel()
        }
        petPanel.onCardClick = { [weak self] sess in
            // clicking a card = you saw that session (per-card ack)
            self?.acked[sess.path] = ackKey(sess)
        }
        petPanel.onSound = { [weak self] on in
            var st = loadState(); st["sound"] = on; saveState(st)
            self?.view.state = st
        }
        view.onToggleSound = { [weak self] in
            var st = loadState()
            st["sound"] = !(st["sound"] as? Bool ?? true)
            saveState(st)
            self?.view.state = st
        }

        // displays changed (unplugged, resolution switch) — keep the pet visible
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.clampToScreen() }

        // popover behavior: any click outside the panel or the pet dismisses it
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.dismissPanelIfOutside()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] ev in self?.dismissPanelIfOutside(); return ev
        }

        // .common mode: scrolling/menu tracking must not freeze the animation
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func clampToScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var o = window.frame.origin
        o.x = max(vis.minX, min(o.x, vis.maxX - window.frame.width))
        o.y = max(vis.minY, min(o.y, vis.maxY - window.frame.height))
        window.setFrameOrigin(o)
    }

    func dismissPanelIfOutside() {
        guard petPanel.panel.isVisible else { return }
        let loc = NSEvent.mouseLocation
        // clicks on the pet itself keep toggle semantics; panel clicks are its buttons
        if !petPanel.panel.frame.contains(loc) && !window.frame.contains(loc) {
            petPanel.panel.orderOut(nil)
        }
    }

    func togglePanel() {
        if petPanel.panel.isVisible {
            petPanel.panel.orderOut(nil)
        } else {
            refreshPanel()
            let pf = petPanel.panel.frame, wf = window.frame
            // place against the screen the PET is on, not whichever is main
            let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var x = wf.minX - pf.width - 10
            if x < vis.minX { x = wf.maxX + 10 }
            petPanel.panel.setFrameOrigin(NSPoint(x: x, y: max(vis.minY, wf.minY)))
            petPanel.panel.orderFront(nil)
            petPanel.fitOnScreen()
        }
    }

    func refreshPanel() {
        let nInput = view.sessions.filter { $0.phase == "input" }.count
        petPanel.refresh(state: view.state, mode: view.mode,
                         sessions: view.sessions, nInput: nInput)
    }

    func readEvents() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: eventsPath),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            if !evPrimed {
                // no spool at launch = nothing stale to skip; whatever appears
                // later is fresh and must be parsed from byte 0
                evPrimed = true
                evOffset = 0
            }
            return
        }
        if !evPrimed {
            // first read after launch: skip everything already in the file —
            // stale notifications must never replay as fresh
            evPrimed = true
            evOffset = size
            return
        }
        if size < evOffset { evOffset = 0 }
        if size == evOffset { return }
        guard let fh = FileHandle(forReadingAtPath: eventsPath) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: evOffset)
        guard let data = try? fh.readToEnd() else { return }
        // consume only up to the last complete line — advancing past a
        // half-appended line would drop that notification forever
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNL]
        evOffset += UInt64(complete.count)
        let text = String(decoding: complete, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let ev = json(Data(line.utf8)),
                  ev["hook_event_name"] as? String == "Notification" else { continue }
            let path = ev["transcript_path"] as? String ?? ""
            notif[path] = (Date().timeIntervalSince1970,
                           ev["message"] as? String ?? "needs your attention")
        }
        if size > 262_144, evOffset == size {
            // keep the hook log from growing forever — but only truncate when
            // we consumed everything AND nothing new landed since our stat,
            // otherwise a notification appended mid-truncate would be lost
            let cur = (try? FileManager.default.attributesOfItem(atPath: eventsPath))?[.size]
            if (cur as? NSNumber)?.uint64Value == size {
                try? Data().write(to: URL(fileURLWithPath: eventsPath))
                evOffset = 0
            }
        }
    }

    func tick() {
        let now = Date().timeIntervalSince1970
        if now - lastPoll > 1.0 {
            lastPoll = now
            readEvents()
            var sessions = scanSessions()
            for (i, s) in sessions.enumerated() {
                if let n = notif[s.path], n.0 > now - s.age,
                   s.phase != "ready" && s.phase != "idle" {
                    sessions[i] = SessionInfo(path: s.path, age: s.age, phase: "input",
                                              doing: String(n.1.prefix(44)), provider: s.provider,
                                              ctx: s.ctx, snippet: s.snippet, label: s.label,
                                              cwd: s.cwd, project: s.project)
                } else if s.phase == "ready", acked[s.path] == ackKey(s) {
                    // acknowledged and same turn since → plain done, no nagging
                    sessions[i].phase = "idle"
                    sessions[i].doing = "done"
                }
            }
            let phases = Dictionary(uniqueKeysWithValues: sessions.map { ($0.path, $0.phase) })
            var state = loadState()
            for (path, ph) in phases {
                let prev = prevPhases[path]
                if petLogEnabled, prev != ph {
                    petLog("\((path as NSString).lastPathComponent) \(prev ?? "-")->\(ph)")
                }
                if ph == "input" && prev != nil && prev != "input" {
                    view.alertUntil = now + 5
                    playSound("/System/Library/Sounds/Ping.aiff", state: state, now: now)
                } else if (prev == "working" || prev == "busy" || prev == "stalled")
                            && ph == "ready" {
                    // stalled counts too: a long-silent session that finally
                    // finishes must still ding and bank XP
                    view.alertUntil = now + 5
                    playSound("/System/Library/Sounds/Glass.aiff", state: state, now: now)
                    var bank = state["sessions"] as? [String: Any] ?? [:]
                    bank["window"] = ((bank["window"] as? NSNumber)?.intValue ?? 0) + 5
                    state["sessions"] = bank
                    saveState(state)
                }
            }
            prevPhases = phases
            let nActive = phases.values.filter { $0 == "working" || $0 == "busy" }.count
            let nInput = phases.values.filter { $0 == "input" }.count
            let nReady = phases.values.filter { $0 == "ready" }.count
            let nStalled = phases.values.filter { $0 == "stalled" }.count
            view.mode = nInput > 0 ? "waiting" : (nActive > 0 ? "working"
                : (nReady > 0 || nStalled > 0 ? "waiting" : "sleeping"))
            view.needsAttention = sessions.contains {
                ($0.phase == "ready" || $0.phase == "input" || $0.phase == "stalled")
                    && acked[$0.path] != ackKey($0)
            }
            view.sessions = sessions
            view.state = loadState()
            if petPanel.panel.isVisible { refreshPanel() }
        }
        view.frameCount += 1
        view.needsDisplay = true
    }

    func playSound(_ path: String, state: [String: Any], now: Double) {
        guard state["sound"] as? Bool ?? true else { return }
        // Ping (needs-input) has its own debounce clock — a Glass moments
        // earlier must never mask the more urgent sound
        if path.hasSuffix("Ping.aiff") {
            guard now - lastPing > soundDebounce else { return }
            lastPing = now
        } else {
            guard now - lastSound > soundDebounce else { return }
            lastSound = now
        }
        petLog("sound \((path as NSString).lastPathComponent)")
        // NSSound fire-and-forget gets released before audio starts; afplay
        // is what the Python pet used and it just works
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [path]
        try? p.run()
    }
}

// test floor: print one JSON line per session and exit — no window, no timer
if CommandLine.arguments.contains("--scan-once") {
    for s in scanSessions() {
        let obj: [String: Any] = ["path": s.path, "phase": s.phase,
                                  "doing": s.doing, "label": s.label]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let line = String(data: d, encoding: .utf8) {
            print(line)
        }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
