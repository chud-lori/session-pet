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
