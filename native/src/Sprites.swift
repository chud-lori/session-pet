// SessionPet — sprite assets (built-ins + drop-in user packs) and rendering.

import AppKit
import Foundation

// MARK: - assets

struct Species {
    let key: String, name: String, emoji: String
    let palette: [String: NSColor], rows: [String]
    // optional hand-authored walk cycle: array of frames, each a rows array
    // (same size as `rows`). Absent → procedural leg-shuffle while walking.
    let walkFrames: [[String]]
}

private func makeSpecies(_ key: String, _ s: [String: Any]) -> Species {
    var pal: [String: NSColor] = [:]
    for (ch, hex) in (s["palette"] as? [String: String]) ?? [:] { pal[ch] = hexColor(hex) }
    let rows = s["rows"] as? [String] ?? []
    let walk = (s["walk"] as? [[String]] ?? []).filter { $0.count == rows.count }
    return Species(key: key, name: s["name"] as? String ?? key,
                   emoji: s["emoji"] as? String ?? "",
                   palette: pal, rows: rows, walkFrames: walk)
}

func loadAssets() -> (order: [String], species: [String: Species]) {
    guard let data = FileManager.default.contents(atPath: assetsPath),
          let root = json(data),
          var order = root["order"] as? [String],
          let dict = root["species"] as? [String: [String: Any]] else {
        fatalError("cannot load \(assetsPath) — run native/export_assets.py")
    }
    var out: [String: Species] = [:]
    for (key, s) in dict { out[key] = makeSpecies(key, s) }
    // user sprite packs: sprites/<key>.json, one species per file, same schema
    // as an assets.json species entry ({"name","emoji","palette","rows"}).
    // Species key = filename stem; packs OVERWRITE built-ins (incl. "egg").
    // Sorted for a deterministic merge order; malformed files are skipped,
    // never fatal.
    let fm = FileManager.default
    for f in ((try? fm.contentsOfDirectory(atPath: spritesDir)) ?? []).sorted()
    where f.hasSuffix(".json") {
        guard let d = fm.contents(atPath: "\(spritesDir)/\(f)"),
              let s = json(d),
              let rows = s["rows"] as? [String], !rows.isEmpty else {
            petLog("sprite pack skipped: \(f)")
            continue
        }
        let key = String(f.dropLast(".json".count))
        out[key] = makeSpecies(key, s)
        // "egg" stays out of the picker — it's the unhatched stage, and picking
        // a sprite is what hatches; an egg.json pack only reskins it
        if key != "egg", !order.contains(key) { order.append(key) }
    }
    return (order, out)
}

let assets = loadAssets()

// MARK: - sprite rendering

func drawSprite(_ key: String, scale: CGFloat, at origin: NSPoint, eyesClosed: Bool,
                mirrored: Bool = false, walkFrame: Int? = nil) {
    guard let sp = assets.species[key] else { return }
    // walk animation: hand-authored frames when the pack ships them,
    // otherwise a procedural 2-frame leg shuffle (bottom rows scissor by
    // one pixel) that works for every species
    var rows = sp.rows
    var shuffle = 0
    if let f = walkFrame {
        if !sp.walkFrames.isEmpty {
            rows = sp.walkFrames[f % sp.walkFrames.count]
        } else {
            shuffle = f % 2 == 0 ? 1 : -1
        }
    }
    let rowCount = rows.count
    let colCount = rows.first?.count ?? 16
    for (y, row) in rows.enumerated() {
        // scissor the feet: last row steps one way, the row above the other
        var stepX = 0
        if shuffle != 0, y >= rowCount - 2 {
            stepX = (y == rowCount - 1 ? shuffle : -shuffle)
        }
        for (x, ch) in row.enumerated() {
            var c = String(ch)
            if c == "." { continue }
            if eyesClosed && (c == "o" || c == "w") { c = "X" }
            guard let color = sp.palette[c] else { continue }
            color.setFill()
            // flip y: pixel row 0 is the TOP of the sprite; mirror x when
            // the pet walks left
            let px = (mirrored ? colCount - 1 - x : x) + (mirrored ? -stepX : stepX)
            NSRect(x: origin.x + CGFloat(px) * scale,
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
