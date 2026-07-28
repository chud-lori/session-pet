// SessionPet — native desktop pixel-art pet for coding agents (Claude Code + Codex).
//
// Port of pet_window.py with the same .state/state.json and native/assets.json
// (exported from the Python sprite maps — run native/export_assets.py after
// editing sprites). Native wins over tkinter: true per-pixel transparency with
// the WHOLE window clickable, retina-crisp sprites, lower footprint.
//
// Build:  swiftc -O native/src/*.swift -o native/SessionPet
// Run:    native/SessionPet [scale]     (default 5)

import AppKit

// test floor: print one JSON line per session and exit — no window, no timer
if CommandLine.arguments.contains("--scan-once") {
    refreshAgentProcs([])  // open `claude --resume` processes count as sessions
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

// diagnostic: `SessionPet --jump <text>` resolves the first session whose
// project/title matches and jumps to its terminal, printing what it found —
// the same code path a card click takes
if let i = CommandLine.arguments.firstIndex(of: "--jump") {
    let needle = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
    let sessions = scanSessions()
    refreshAgentProcs(sessions)
    guard let sess = sessions.first(where: {
        needle.isEmpty || $0.project.localizedCaseInsensitiveContains(needle)
            || $0.label.localizedCaseInsensitiveContains(needle)
    }) else {
        print("no session matching \(needle.isEmpty ? "<any>" : needle)")
        exit(1)
    }
    print("session: \(sess.project) — \(sess.label)")
    print("cwd:     \(sess.cwd ?? "-")")
    if let ap = agentProcs[sess.path] {
        print("process: pid=\(ap.pid) tty=\(ap.tty.isEmpty ? "-" : ap.tty)")
        print("host:    \(ap.bundleID ?? "UNKNOWN — no GUI ancestor")")
    } else {
        print("process: NOT FOUND (no jump possible)")
        exit(2)
    }
    jumpToTerminal(sess)
    print("jumped.")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
