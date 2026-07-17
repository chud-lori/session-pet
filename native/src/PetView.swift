// SessionPet — the pet sprite view + its window-level interactions.

import AppKit

final class PetView: NSView {
    var scale: CGFloat = 5
    var frameCount = 0
    var mode = "waiting"
    var facing: CGFloat = 1   // 1 faces right, -1 faces left (walking)
    var walking = false
    var sessions: [SessionInfo] = []
    var state: [String: Any] = loadState()
    var alertUntil = 0.0
    var exciteUntil = 0.0      // excited-hop burst window (muted-friendly alert)
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

        // QUIET BASELINE, LOUD ALERT: constant bobbing trained the eye to
        // ignore vertical motion, so alerts drowned in it. Now only working/
        // walking bounce; waiting/sleeping sit still except a tiny "breath"
        // every ~4s — making any alert motion unmistakable by contrast.
        let bob: CGFloat
        if walking || mode == "working" {
            bob = CGFloat((frameCount / 2) % 2) * (s / 2)
        } else {
            bob = frameCount % 16 == 0 ? s / 4 : 0  // single subtle breath
        }
        // alert = a DIFFERENT motion, not a bigger bob: hops combined with a
        // rapid left-right wiggle (the pet never wiggles otherwise); while
        // unacknowledged, a reminder hop fires every ~12s against stillness.
        var hop: CGFloat = 0
        var wiggle = false
        let nowT = Date().timeIntervalSince1970
        if nowT < exciteUntil {
            let phase = CGFloat((nowT * 2).truncatingRemainder(dividingBy: 1))
            hop = abs(sin(phase * .pi)) * 2.2 * s
            wiggle = Int(nowT * 6) % 2 == 0  // 3 flips/sec — unmistakable
        } else if needsAttention, frameCount % 48 < 6 {
            let phase = CGFloat(frameCount % 48) / 6
            hop = abs(sin(phase * .pi)) * 1.2 * s
        }
        let spriteW = CGFloat(sp.rows.first?.count ?? 16) * s
        let ox = (bounds.width - spriteW) / 2
        let baseY = 3.5 * s // above caption + dots

        // ground shadow
        NSColor(white: 0, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width / 2 - 7 * s, y: baseY - 0.8 * s,
                                    width: 14 * s, height: 1.6 * s)).fill()

        let blink = mode == "sleeping" || frameCount % 16 == 0
        drawSprite(spriteKey, scale: s, at: NSPoint(x: ox, y: baseY + bob + hop),
                   eyesClosed: blink, mirrored: (facing < 0) != wiggle,
                   walkFrame: walking ? frameCount / 2 : nil)

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
        // shrink-to-fit: "👑Ember · Lv.16" outgrew the window at full size —
        // step the font down until the plate fits inside the canvas
        var capSize = s + 6
        var attrs: [NSAttributedString.Key: Any] = [:]
        var sz = NSSize.zero
        while capSize >= 8 {
            let f = NSFont(name: "Menlo-Bold", size: capSize) ?? .boldSystemFont(ofSize: capSize)
            attrs = [.font: f, .foregroundColor: cFG]
            sz = caption.size(withAttributes: attrs)
            if sz.width + 16 <= bounds.width { break }
            capSize -= 1
        }
        // name plate: rounded dark pill keeps the caption readable on ANY
        // background (stroked text looked ragged over white windows).
        // During an alert burst it FLASHES yellow — luminance change is the
        // strongest peripheral-vision trigger there is.
        let flashing = nowT < exciteUntil && frameCount % 2 == 0
        let pad: CGFloat = 6
        let plate = NSRect(x: (bounds.width - sz.width) / 2 - pad, y: 0.2 * s - 2,
                           width: sz.width + 2 * pad, height: sz.height + 4)
        (flashing ? cWarn.withAlphaComponent(0.95)
                  : NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 0.82)).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        if flashing {
            attrs[.foregroundColor] = NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1)
        }
        caption.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: 0.2 * s),
                     withAttributes: attrs)
    }
}
