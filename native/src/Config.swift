// SessionPet — paths, tunable constants, colors, and small shared helpers.

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
// drop-in user packs (codex-pets model): one species JSON per file, any
// afplay-playable sound file
let spritesDir = "\(petRoot)/sprites"
let soundsDir = "\(petRoot)/sounds"

let workingWithin = 15.0, waitingWithin = 300.0, busyGrace = 300.0
let recentWindow = 3600.0, soundDebounce = 8.0
let inputTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

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

// MARK: - shared formatting helpers

func tildify(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func fmtTokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1000 ? "\(n / 1000)k" : "\(n)"
}

func fmtAge(_ age: Double) -> String {
    if age < 60 { return "\(Int(age))s" }
    if age < 3600 { return "\(Int(age / 60))m" }
    return "\(Int(age / 3600))h"
}
