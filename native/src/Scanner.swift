// SessionPet — session scanning (ported from pet_window.py): transcript
// discovery and per-provider tail parsing for Claude Code + Codex.

import Foundation

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
    var customTitle: String? = nil  // manual /rename — beats the AI title
    var agentName: String? = nil    // user-assigned agent name — beats dir badge
    var newTurn = false  // a real user prompt arrived AFTER the last end_turn
    var newTurnAt: Double? = nil  // epoch seconds of that prompt, when known
    var hookContinuation = false  // Stop-hook feedback arrived AFTER end_turn
}

func ackKey(_ s: SessionInfo) -> String {
    // snippet alone is often "" (input/stalled turns); ctx grows every turn,
    // so together they identify a turn without depending on volatile mtime
    "\(s.snippet)|\(s.ctx ?? 0)"
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

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Double? {
    (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
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
        // manual renames beat everything: /rename writes custom-title, naming
        // the agent writes agent-name ("hvl") — user intent > derived names
        if info.customTitle == nil, type == "custom-title" {
            info.customTitle = ev["customTitle"] as? String
        }
        if info.agentName == nil, type == "agent-name" {
            info.agentName = ev["agentName"] as? String
        }
        if decided { continue }  // keep scanning the tail for names/cwd (cached by mtime)
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
            var isPrompt = false
            if let s = content as? String {
                // local-command echoes and interruption markers are meta,
                // not real prompts
                isPrompt = !s.hasPrefix("<local-command") && !s.hasPrefix("[Request interrupted")
            } else if let blocks = content as? [[String: Any]],
                      !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                isPrompt = true
            }
            if isPrompt {
                info.newTurn = true
                // when the prompt itself happened — an unanswered prompt from
                // hours ago (session closed mid-send) is abandoned, not "processing"
                if let ts = ev["timestamp"] as? String {
                    info.newTurnAt = parseISO(ts)
                }
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
// how long "finished — waiting for you" stays before quietly fading to idle
// when unacknowledged (clicking the card clears it immediately)
let readyNag = 180.0
var readyHold: [String: (String, Double)] = [:]  // path → (turn key, first seen)

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
                } else if info.newTurn && age < busyGrace
                            && (info.newTurnAt.map { now - $0 < 180 } ?? true) {
                    // only a RECENT unanswered prompt means "processing" —
                    // an old one is an abandoned send, not an active turn
                    // prompt submitted, Claude thinking — no assistant event yet
                    phase = "working"; doing = "processing your prompt…"
                } else if age < waitingWithin {
                    // end_turn is authoritative even at fresh mtime —
                    // housekeeping events keep touching the file after a turn
                    phase = "ready"; doing = "finished — waiting for you"
                    // track when this turn's ready state was first seen (also
                    // feeds the stop-hook intermediate hold below)
                    let key = "\(info.snippet)|\(info.ctx ?? 0)"
                    // seed from the event's real age, not first-noticed time —
                    // otherwise a pet restart resets every fade timer
                    if readyHold[path]?.0 != key {
                        readyHold[path] = (key, now - min(age, readyNag))
                    }
                    let readySince = now - readyHold[path]!.1
                    if provider == "claude", readySince < readyConfirm,
                       age < readyConfirm + 30 {
                        // a Claude end_turn may be a stop-hook/queued-msg
                        // intermediate: hold until it survives readyConfirm
                        phase = "working"; doing = "finishing up…"
                    } else if readySince > readyNag {
                        // hybrid ack: unclicked for a while = you saw it;
                        // fade to idle instead of nagging forever (clicking
                        // the card still clears it instantly)
                        phase = "idle"; doing = "done"
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
            // path component (badge pill ellipsizes long names)
            let fallback = projectLabel(path, provider)
            let cwd = info.cwd
                ?? ((fallback.hasPrefix("~") || fallback.hasPrefix("/")) ? fallback : nil)
            // badge: the user's rename (agent-name) wins; else dir name
            var project = info.agentName
                ?? ((cwd ?? fallback) as NSString).lastPathComponent
            if project.isEmpty || project == "~" { project = provider }
            // title: manual /rename (custom-title) wins; else AI title; else path
            let label = info.customTitle ?? info.title
                ?? info.cwd.map(tildify) ?? fallback
            out.append(SessionInfo(path: path, age: dispAge, phase: phase, doing: doing,
                                   provider: provider, ctx: info.ctx,
                                   snippet: info.snippet, label: label,
                                   cwd: cwd, project: project))
        }
    }
    return out.sorted { $0.age < $1.age }
}
