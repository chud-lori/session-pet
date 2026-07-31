// SessionPet — Touch Bar marquee.
//
// A background .accessory app can't show a normal NSTouchBar (the system only
// shows the FRONTMOST app's bar). To put persistent, scrolling text on the
// Touch Bar regardless of which app is focused, we use the private DFRFoundation
// "system modal" Control Strip API — the same undocumented route Pock / MTMR /
// BetterTouchTool use. Symbols are pulled at runtime (dlsym + ObjC runtime) so
// nothing links against the private framework at build time; if any symbol is
// missing (future macOS breakage) the whole thing degrades to a silent no-op.

import AppKit
import Foundation

// MARK: - private DFR symbols, resolved at runtime

private let dfrHandle = dlopen(
    "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

private func dfr<T>(_ name: String, _ type: T.Type) -> T? {
    guard let h = dfrHandle, let sym = dlsym(h, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

private typealias FnBool = @convention(c) (Bool) -> Void
private typealias FnIdPresence = @convention(c) (NSString, Bool) -> Void

private let dfrShowCloseBox = dfr("DFRSystemModalShowsCloseBoxWhenFrontMost", FnBool.self)
private let dfrSetPresence  = dfr("DFRElementSetControlStripPresenceForIdentifier",
                                  FnIdPresence.self)

// MARK: - scrolling marquee view (Core Animation, so it stays smooth while our
// 4 fps tick sleeps between polls)

final class MarqueeView: NSView {
    private let textLayer = CATextLayer()
    private var shown = ""
    var text: String {
        get { shown }
        set { if newValue != shown { shown = newValue; relayout() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // pin to a deterministic size so vertical centering is stable no matter
        // how the Touch Bar lays the item out
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 480).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        textLayer.contentsScale = 2          // Touch Bar is retina
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        layer?.addSublayer(textLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); relayout() }

    private func relayout() {
        let font = NSFont(name: "Menlo-Bold", size: 14) ?? .boldSystemFont(ofSize: 14)
        textLayer.font = font
        textLayer.fontSize = 14
        textLayer.string = shown
        // size the layer from the font's FULL glyph box (ascender→descender),
        // not the string's reported height — the latter is too tight for a bold
        // font and clipped descenders (g, y, p) at the bottom
        let lineH = ceil(font.ascender - font.descender)
        let textW = ceil((shown as NSString).size(withAttributes: [.font: font]).width)
        let h = bounds.height
        let y = ((h - lineH) / 2).rounded()   // true vertical center
        textLayer.removeAnimation(forKey: "marquee")
        if textW <= bounds.width {
            // fits — center it, no scrolling
            textLayer.frame = CGRect(x: ((bounds.width - textW) / 2).rounded(), y: y,
                                     width: textW, height: lineH)
        } else {
            // scroll right→left on repeat at a steady ~70 pt/s
            textLayer.frame = CGRect(x: 0, y: y, width: textW, height: lineH)
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = bounds.width
            a.toValue = -textW
            a.duration = Double(bounds.width + textW) / 70.0
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            textLayer.add(a, forKey: "marquee")
        }
    }
}

// MARK: - controller

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private let itemId = NSTouchBarItem.Identifier("com.session-pet.marquee")
    private let trayId = NSTouchBarItem.Identifier("com.session-pet.tray")
    private let marquee = MarqueeView(frame: NSRect(x: 0, y: 0, width: 560, height: 30))
    private var bar: NSTouchBar?
    private var presented = false
    private var current = ""
    private let available = dfrSetPresence != nil   // private API actually there?

    override init() {
        super.init()
        guard available else {
            petLog("touchbar: DFR private API unavailable — marquee disabled")
            return
        }
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [.flexibleSpace, itemId, .flexibleSpace]
        b.principalItemIdentifier = itemId
        bar = b

        // register a persistent Control Strip presence + a tray icon that can
        // re-summon the marquee if the user swipes it away
        dfrShowCloseBox?(false)
        let tray = NSCustomTouchBarItem(identifier: trayId)
        let btn = NSButton(title: "🐾", target: self, action: #selector(reveal))
        btn.bezelStyle = .rounded
        tray.view = btn
        _ = (NSTouchBarItem.self as AnyObject).perform(
            NSSelectorFromString("addSystemTrayItem:"), with: tray)
        dfrSetPresence?(trayId.rawValue as NSString, true)
    }

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == itemId else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = marquee
        return item
    }

    // show `text` on the bar (idempotent — updating text does NOT restart the
    // scroll, and re-calling while already up is a no-op)
    func show(_ text: String) {
        guard available else { return }
        if !presented { present(); presented = true }
        if text != current { current = text; marquee.text = text }
    }

    func hide() {
        guard available, presented else { return }
        dismiss()
        presented = false
        current = ""
    }

    @objc private func reveal() { if !presented, current.isEmpty == false { present(); presented = true } }

    private func present() {
        guard let bar = bar else { return }
        // modern private selector: presentSystemModalTouchBar:systemTrayItemIdentifier:
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        let cls = NSTouchBar.self as AnyObject
        if cls.responds(to: sel) {
            _ = cls.perform(sel, with: bar, with: trayId.rawValue as NSString)
        } else {
            petLog("touchbar: presentSystemModal selector missing")
        }
    }

    private func dismiss() {
        guard let bar = bar else { return }
        let cls = NSTouchBar.self as AnyObject
        for name in ["dismissSystemModalTouchBar:", "minimizeSystemModalTouchBar:"] {
            let sel = NSSelectorFromString(name)
            if cls.responds(to: sel) { _ = cls.perform(sel, with: bar); return }
        }
    }
}
