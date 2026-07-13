// SessionPet — shared pet state (same .state/state.json as the Python pet)
// and XP/stage logic.

import Foundation

let stages: [(Int, String)] = [(0, "egg"), (30, "hatchling"), (200, "adult"), (1000, "legendary")]
let stageNext = ["egg": "hatchling", "hatchling": "adult", "adult": "legendary"]

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
