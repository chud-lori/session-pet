// SessionPet — jump from a session card back to the terminal/IDE running it.
//
// No hook and no env-var bridge is needed: the agent process is already
// visible in the process list, and two things it carries identify its window
// exactly — its controlling TTY (which iTerm2 and Terminal.app expose per
// tab, so we can select the precise tab) and its ancestry (walking the ppid
// chain to the first GUI app gives the hosting terminal/IDE bundle id).
//
// Requires Automation permission the first time an AppleScript targets a
// terminal; if the user declines, the app-level activate still worked.

import AppKit
import Foundation

struct AgentProc {
    var pid: pid_t
    var tty: String        // "ttys004", or "" when detached
    var cwd: String        // resolved via lsof
    var resumeID: String?  // `claude --resume <id>`
    var bundleID: String?  // hosting GUI app, from the ppid chain
}

// path → the process running that session; refreshed on the same cadence as
// the open-session scan (they parse the same `ps` output)
var agentProcs: [String: AgentProc] = [:]

private func psSnapshot() -> (procs: [(pid: pid_t, ppid: pid_t, tty: String, cmd: String)],
                              parents: [pid_t: pid_t]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,ppid=,tty=,command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return ([], [:]) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var procs: [(pid: pid_t, ppid: pid_t, tty: String, cmd: String)] = []
    var parents: [pid_t: pid_t] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        // pid ppid tty command… — command itself contains spaces
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1])
        else { continue }
        let tty = parts[2] == "??" ? "" : String(parts[2])
        let cmd = parts[3...].joined(separator: " ")
        parents[pid] = ppid
        procs.append((pid: pid, ppid: ppid, tty: tty, cmd: cmd))
    }
    return (procs, parents)
}

// batch-resolve working directories (one lsof call for every agent process)
private func cwds(of pids: [pid_t]) -> [pid_t: String] {
    guard !pids.isEmpty else { return [:] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-a", "-d", "cwd", "-Fpn",
                   "-p", pids.map(String.init).joined(separator: ",")]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    // -F output is one field per line: "p<pid>" then "n<path>"
    var out: [pid_t: String] = [:]
    var cur: pid_t = 0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if line.hasPrefix("p") {
            cur = pid_t(line.dropFirst()) ?? 0
        } else if line.hasPrefix("n"), cur != 0 {
            out[cur] = String(line.dropFirst())
        }
    }
    return out
}

// first ancestor that is a GUI application = the terminal/IDE hosting it
private func hostBundleID(_ pid: pid_t, _ parents: [pid_t: pid_t]) -> String? {
    var cur = pid
    for _ in 0..<20 {
        guard let next = parents[cur], next > 1 else { return nil }
        cur = next
        if let app = NSRunningApplication(processIdentifier: cur),
           let bid = app.bundleIdentifier {
            return bid
        }
    }
    return nil
}

/// Rebuild the session → process map. Also refreshes `openSessionIDs`
/// (same `ps` output, so the scanner's quiet-but-open check stays free).
func refreshAgentProcs(_ sessions: [SessionInfo]) {
    let snap = psSnapshot()
    var candidates: [(proc: (pid: pid_t, ppid: pid_t, tty: String, cmd: String),
                      resume: String?)] = []
    var openIDs: Set<String> = []
    for pr in snap.procs {
        let argv = pr.cmd.split(separator: " ").map(String.init)
        guard let first = argv.first else { continue }
        let exe = (first as NSString).lastPathComponent
        guard exe == "claude" || exe == "codex" else { continue }
        var resume: String? = nil
        if let i = argv.firstIndex(of: "--resume"), i + 1 < argv.count {
            resume = argv[i + 1]
            openIDs.insert(argv[i + 1])
        }
        candidates.append((proc: pr, resume: resume))
    }
    openSessionIDs = openIDs
    let dirs = cwds(of: candidates.map { $0.proc.pid })

    var out: [String: AgentProc] = [:]
    for sess in sessions {
        let stem = ((sess.path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        // untildify: SessionInfo.cwd is display-formatted
        let want = sess.cwd.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        let match = candidates.first { c in
            if let r = c.resume, r == stem { return true }
            guard let want else { return false }
            return dirs[c.proc.pid] == want
        }
        guard let m = match else { continue }
        out[sess.path] = AgentProc(pid: m.proc.pid, tty: m.proc.tty,
                                   cwd: dirs[m.proc.pid] ?? "",
                                   resumeID: m.resume,
                                   bundleID: hostBundleID(m.proc.pid, snap.parents))
    }
    agentProcs = out
}

private func runAppleScript(_ src: String) {
    guard let script = NSAppleScript(source: src) else { return }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    if let err { petLog("applescript error: \(err)") }
}

private func escaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

// Ghostty (1.2+) ships a real scripting dictionary: application → windows →
// tabs → terminals, where a terminal knows its live `working directory` and
// `focus` raises its window, tab and split in one call. There is no tty
// property, so the exact surface is identified by pairing that working
// directory with the tab name — which carries the session's own title,
// because Claude Code sets it (e.g. "✳ Review Slack thread about HVL").
// Neither key alone is enough: several tabs commonly share a repo, and a
// title alone can outlive the directory it was created in.
private func jumpGhostty(_ sess: SessionInfo, bundleID: String) {
    let cwd = sess.cwd.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 } ?? ""
    let label = sess.label
    let hasCwd = !cwd.isEmpty, hasLabel = !label.isEmpty
    guard hasCwd || hasLabel else { return }
    var passes: [String] = []
    if hasCwd, hasLabel {
        passes.append("""
                if (working directory of trm is "\(escaped(cwd))") \
        and (name of t contains "\(escaped(label))") then
        """)
    }
    // then either key on its own — a renamed tab or a session that cd'd away
    // should still land on the right window, just less certainly
    if hasLabel {
        passes.append("if name of t contains \"\(escaped(label))\" then")
    }
    if hasCwd {
        passes.append("if working directory of trm is \"\(escaped(cwd))\" then")
    }
    let body = passes.map { cond in
        """
        repeat with w in windows
            repeat with t in tabs of w
                repeat with trm in terminals of t
                    \(cond)
                        focus trm
                        return
                    end if
                end repeat
            end repeat
        end repeat
        """
    }.joined(separator: "\n")
    runAppleScript("tell application id \"\(escaped(bundleID))\"\n\(body)\nend tell")
}

/// Bring the terminal (and, where possible, the exact tab) running `sess`
/// to the front. Returns false when we could not identify the process.
@discardableResult
func jumpToTerminal(_ sess: SessionInfo) -> Bool {
    guard let ap = agentProcs[sess.path] else { return false }
    petLog("jump \(sess.project) pid=\(ap.pid) tty=\(ap.tty) app=\(ap.bundleID ?? "-")")
    if let bid = ap.bundleID,
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
        app.activate(options: [.activateAllWindows])
    }
    let bid = (ap.bundleID ?? "").lowercased()
    let dev = ap.tty.isEmpty ? "" : "/dev/\(ap.tty)"
    if bid.contains("iterm"), !dev.isEmpty {
        // target by bundle id, never by name: iTerm2's scripting name is
        // "iTerm", so `tell application "iTerm2"` fails to resolve entirely
        // and the whole block silently does nothing.
        // tty is exact: no title guessing, no session-id bridge
        runAppleScript("""
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escaped(dev))" then
                            select w
                            tell w to select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    } else if bid == "com.apple.terminal", !dev.isEmpty {
        runAppleScript("""
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped(dev))" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    } else if bid.contains("ghostty") {
        jumpGhostty(sess, bundleID: ap.bundleID ?? "com.mitchellh.ghostty")
    } else if !bid.isEmpty {
        // Everything else (Ghostty, VS Code, JetBrains, …) exposes no
        // scriptable session/tty model, so fall back to the accessibility
        // tree: raise the window whose title mentions the project, then —
        // for apps using native macOS tabs, which Ghostty does — click the
        // tab with that title too. Title matching is best-effort: two tabs
        // in the same folder are indistinguishable from the outside.
        let needles = [sess.project, sess.cwd.map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0 }.filter { !$0.isEmpty && $0 != "~" }
        let appName = NSRunningApplication
            .runningApplications(withBundleIdentifier: ap.bundleID ?? "").first?
            .localizedName ?? ""
        guard !appName.isEmpty, let needle = needles.first else { return true }
        runAppleScript("""
        tell application "System Events"
            tell process "\(escaped(appName))"
                repeat with w in windows
                    if name of w contains "\(escaped(needle))" then
                        perform action "AXRaise" of w
                        -- native tab bar (Ghostty, Terminal-style tabbing):
                        -- pick the tab whose title matches as well
                        try
                            repeat with tg in (tab groups of w)
                                repeat with rb in (radio buttons of tg)
                                    if name of rb contains "\(escaped(needle))" then
                                        click rb
                                        exit repeat
                                    end if
                                end repeat
                            end repeat
                        end try
                        return
                    end if
                end repeat
            end tell
        end tell
        """)
    }
    return true
}
