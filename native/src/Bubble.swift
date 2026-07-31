// SessionPet — the speech bubble: a small borderless window that pops above the
// pet to "call out" the event that needs you (permission / decision / done).
//
// The pet window itself is only ~18×23 sprite cells, so callout text can't fit
// inside it; a separate, self-sizing bubble window sits just above the pet's
// head, tracks it as it walks, and fades itself after a few seconds.

import AppKit

final class BubbleView: NSView {
    var text = ""
    var bg = NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 0.95)
    var fg = NSColor.white
    let tailH: CGFloat = 8, padX: CGFloat = 12, padY: CGFloat = 7, radius: CGFloat = 9

    var font: NSFont { NSFont(name: "Menlo-Bold", size: 12) ?? .boldSystemFont(ofSize: 12) }

    // window size that fits `text` plus padding and the downward tail
    func fittingSize(_ text: String) -> NSSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + padX * 2,
                      height: ceil(s.height) + padY * 2 + tailH)
    }

    override func draw(_ dirtyRect: NSRect) {
        // rounded body sits above the tail; tail points straight down at the pet
        let body = NSRect(x: 0, y: tailH, width: bounds.width, height: bounds.height - tailH)
        let cx = bounds.width / 2
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - 6, y: tailH + 0.5))
        tail.line(to: NSPoint(x: cx, y: 0))
        tail.line(to: NSPoint(x: cx + 6, y: tailH + 0.5))
        tail.close()
        bg.setFill()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
        tail.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let ts = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - ts.width) / 2,
                                            y: tailH + (body.height - ts.height) / 2),
                                withAttributes: attrs)
    }
}

final class Bubble {
    let win: NSWindow
    let view = BubbleView()
    private var hideToken = 0

    init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        // one notch above the pet's .floating level so it always sits on top of
        // the sprite, and clicks fall through to whatever is behind it
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
    }

    var isVisible: Bool { win.isVisible }

    // pop `text` above the pet, in `color`, auto-hiding after `seconds`
    func show(_ text: String, color: NSColor, over petFrame: NSRect, seconds: Double = 6) {
        view.text = text
        view.bg = color
        let sz = view.fittingSize(text)
        win.setContentSize(sz)
        view.frame = NSRect(origin: .zero, size: sz)
        view.needsDisplay = true
        reposition(over: petFrame)
        win.orderFront(nil)
        // newest callout wins: bump the token so the previous hide timer no-ops
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.win.orderOut(nil)
        }
    }

    // keep the tail glued to the pet's head as it wanders
    func reposition(over petFrame: NSRect) {
        guard win.isVisible else { return }
        let w = win.frame.width, h = win.frame.height
        var x = petFrame.midX - w / 2
        var y = petFrame.maxY - 6   // slight overlap so the tail meets the head
        if let vis = (win.screen ?? NSScreen.main)?.visibleFrame {
            x = max(vis.minX + 4, min(x, vis.maxX - w - 4))
            if y + h > vis.maxY { y = petFrame.minY - h + 6 }  // no room above → below
        }
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
