// SessionPet — the details panel: XP header, phase chips, session cards,
// species picker, and settings.

import AppKit

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true } // content starts at the TOP
}

class FlippedView: NSView {
    override var isFlipped: Bool { true } // manual top-down card layout
}

class ClickableCard: FlippedView {
    var onClick: (() -> Void)?
    private var downAt: NSPoint = .zero
    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation }
    override func mouseUp(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if abs(m.x - downAt.x) + abs(m.y - downAt.y) < 6 { onClick?() }
    }
}

// one PERSISTENT expandable card per session (code-island style): the surface
// itself encodes state (phase-tinted fill + 1px phase border). v2 layout:
// identity strip (project badge + age) → wrapping 2-line title (hero, neutral,
// SF Semibold) → phase-colored status. Expanded shows the cwd path (never the
// transcript UUID), provider/ctx meta, and the last snippet. Labels update in
// place so a refresh never destroys the view mid-click.
final class SessionCard: ClickableCard {
    private let badgePill = NSView()
    private let badge = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        // Menlo only for identifiers: badge, age, path, token counts
        badge.font = NSFont(name: "Menlo-Bold", size: 10)
        badge.alignment = .center
        badge.lineBreakMode = .byTruncatingTail
        badgePill.wantsLayer = true
        badgePill.layer?.cornerRadius = 8 // capsule on the 16pt pill, matches chips
        badgePill.addSubview(badge)
        ageLabel.font = NSFont(name: "Menlo", size: 10)
        ageLabel.textColor = cMuted
        ageLabel.alignment = .right
        // SF Pro for prose: title is the hero, wraps to 2 full-width lines
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = cFG
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping // wrap to line 2; ellipsis via truncatesLastVisibleLine
        titleLabel.cell?.truncatesLastVisibleLine = true
        status.font = NSFont.systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        pathLabel.font = NSFont(name: "Menlo", size: 10)
        pathLabel.textColor = cMuted
        pathLabel.lineBreakMode = .byTruncatingMiddle
        meta.font = NSFont(name: "Menlo", size: 10)
        meta.textColor = cMuted
        meta.lineBreakMode = .byTruncatingTail
        snippet.font = NSFont.systemFont(ofSize: 11)
        snippet.textColor = cFG
        snippet.maximumNumberOfLines = 3
        snippet.cell?.truncatesLastVisibleLine = true
        for l in [badge, ageLabel, titleLabel, status, pathLabel, meta, snippet] {
            l.isSelectable = false // selectable labels swallow the card's click
        }
        for v in [badgePill, ageLabel, titleLabel, status, pathLabel, meta, snippet] {
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // update every label/color/frame in place and resize the card
    func update(_ sess: SessionInfo, open: Bool, width: CGFloat) {
        let padH: CGFloat = 12, padV: CGFloat = 10
        let W = width - 2 * padH
        let color = ["working": cAccent, "busy": cAccent, "input": cInput,
                     "ready": cWarn, "stalled": cStalled][sess.phase] ?? cMuted
        let idle = sess.phase == "idle"
        layer?.backgroundColor = color.withAlphaComponent(idle ? 0.04 : 0.07).cgColor
        layer?.borderColor = color.withAlphaComponent(
            sess.phase == "input" ? 0.45 : (idle ? 0.15 : 0.35)).cgColor

        // row 1 — identity strip (h 16): project badge left, one age top-right;
        // badge hides when the title itself is the path (no duplication)
        var cy = padV
        let cwdDisp = sess.cwd.map(tildify)
        let hideBadge = sess.project.isEmpty || sess.label == cwdDisp
        badgePill.isHidden = hideBadge
        if !hideBadge {
            badge.stringValue = sess.project
            let pc = projectColor(sess.project)
            badge.textColor = pc
            badgePill.layer?.backgroundColor = pc.withAlphaComponent(0.16).cgColor
            let cell = badge.cell!.cellSize          // includes the cell's own h-padding
            let textH = ceil(cell.height)            // 11 for Menlo-Bold 10
            let labelW = min(ceil(cell.width), 108)  // pill still caps at 120 total
            badgePill.frame = NSRect(x: padH, y: cy, width: labelW + 12, height: 16)
            badge.frame = NSRect(x: 6, y: (16 - textH) / 2, width: labelW, height: textH)
        }
        ageLabel.stringValue = fmtAge(sess.age)
        // same text-top as the badge label ((16-11)/2 = 2.5) so both Menlo 10
        // baselines land together on the identity row
        ageLabel.frame = NSRect(x: width - padH - 48, y: cy + 2.5, width: 48, height: 12)
        cy += 22

        // row 2 — title (hero), wraps to at most 2 full-width lines
        titleLabel.stringValue = sess.label
        let th = NSAttributedString(string: sess.label, attributes:
            [.font: titleLabel.font!]).boundingRect(
                with: NSSize(width: W, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]).height
        let lineH = ceil(titleLabel.font!.ascender - titleLabel.font!.descender) // 16 for SF 13 semibold
        titleLabel.frame = NSRect(x: padH, y: cy, width: W, height: min(ceil(th) + 1, 2 * lineH + 1))
        cy += titleLabel.frame.height + 4

        // row 3 — status, the only phase-colored text
        status.stringValue = sess.doing
        status.textColor = idle ? cMuted : color
        status.frame = NSRect(x: padH, y: cy, width: W, height: 15)
        cy += 15

        pathLabel.isHidden = !open || cwdDisp == nil
        meta.isHidden = !open
        snippet.isHidden = !open || sess.snippet.isEmpty
        if open {
            cy += 6
            if let p = cwdDisp {
                pathLabel.stringValue = p
                pathLabel.frame = NSRect(x: padH, y: cy, width: W, height: 13)
                cy += 15
            }
            var m: [String] = [sess.provider]
            if let ctx = sess.ctx { m.append("ctx \(fmtTokens(ctx))") }
            meta.stringValue = m.joined(separator: " · ")
            meta.frame = NSRect(x: padH, y: cy, width: W, height: 13)
            cy += 15
            if !sess.snippet.isEmpty {
                snippet.stringValue = "“\(sess.snippet)”"
                let sh = snippet.attributedStringValue.boundingRect(
                    with: NSSize(width: W, height: 48),
                    options: [.usesLineFragmentOrigin]).height
                snippet.frame = NSRect(x: padH, y: cy, width: W,
                                       height: min(ceil(sh) + 2, 48))
                cy += snippet.frame.height + 2
            }
        }
        setFrameSize(NSSize(width: width, height: cy + padV))
    }
}

final class Panel {
    let panel: NSPanel
    let title = NSTextField(labelWithString: "")
    let xpLabel = NSTextField(labelWithString: "") // stage · XP · next, one line
    let chipsRow = NSStackView() // colored per-state count pills
    let bar = NSView(), barFill = NSView()
    let sessionDoc = FlippedView()
    let sessionScroll = NSScrollView()
    var sessionHeight: NSLayoutConstraint!
    var expanded: Set<String> = []  // session card expansion state, by path
    var cards: [String: SessionCard] = [:]  // persistent card per session path
    private var emptyLabel: NSTextField?
    var onCardClick: ((SessionInfo) -> Void)?
    private var lastRefresh: ([String: Any], String, [SessionInfo], Int)?
    let walkCheck = NSButton(checkboxWithTitle: "let the pet wander around",
                             target: nil, action: nil)
    let soundCheck = NSButton(checkboxWithTitle: "sound when an agent needs me",
                              target: nil, action: nil)
    let settingsBox = NSStackView()
    let settingsToggle = NSButton(title: "settings ▸", target: nil, action: nil)
    var pickButtons: [String: NSButton] = [:]
    var onPick: ((String) -> Void)?
    var onSound: ((Bool) -> Void)?
    var onWalk: ((Bool) -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = cBG.cgColor
        card.layer?.cornerRadius = 12

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        title.font = NSFont(name: "Menlo-Bold", size: 15)
        title.textColor = cFG
        xpLabel.font = NSFont(name: "Menlo", size: 11)
        xpLabel.textColor = cMuted
        chipsRow.orientation = .horizontal
        chipsRow.spacing = 6

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        bar.layer?.cornerRadius = 3
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 332).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = cAccent.cgColor
        barFill.layer?.cornerRadius = 3
        bar.addSubview(barFill)

        // session cards scroll inside a capped height (code-island style);
        // manual frames on a flipped document view — autolayout documentViews
        // silently collapse to zero height and never scroll
        let clip = FlippedClipView()
        clip.drawsBackground = false
        sessionScroll.contentView = clip
        sessionScroll.documentView = sessionDoc
        sessionScroll.hasVerticalScroller = true
        sessionScroll.autohidesScrollers = true
        sessionScroll.drawsBackground = false
        sessionScroll.verticalScrollElasticity = .allowed
        sessionScroll.scrollerStyle = .overlay // cards use the full 332 content width
        // AppKit resets scrollerStyle to the system preference when it changes
        // (mouse plug/unplug, "Show scroll bars" setting) — re-assert overlay so
        // a legacy scroller never eats ~15pt of the fixed 332pt card width
        NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main) { [weak sessionScroll] _ in
            sessionScroll?.scrollerStyle = .overlay
        }
        sessionScroll.translatesAutoresizingMaskIntoConstraints = false
        sessionHeight = sessionScroll.heightAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            sessionScroll.widthAnchor.constraint(equalToConstant: 332),
            sessionHeight,
        ])

        // species picker grid (always visible — native panel has the room)
        let grid = NSStackView(); grid.orientation = .vertical; grid.spacing = 4
        var row: NSStackView? = nil
        for (i, key) in assets.order.enumerated() {
            if i % 4 == 0 { row = NSStackView(); row!.spacing = 4; grid.addArrangedSubview(row!) }
            let b = NSButton(image: spriteImage(key, scale: 2), target: nil, action: nil)
            b.bezelStyle = .regularSquare
            b.isBordered = true
            b.setButtonType(.momentaryPushIn)
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.target = self
            b.action = #selector(pick(_:))
            pickButtons[key] = b
            row!.addArrangedSubview(b)
        }

        soundCheck.attributedTitle = Panel.buttonTitle("sound when an agent needs me")
        soundCheck.target = self
        soundCheck.action = #selector(soundToggled(_:))

        walkCheck.attributedTitle = Panel.buttonTitle("let the pet wander around")
        walkCheck.target = self
        walkCheck.action = #selector(walkToggled(_:))

        let quit = NSButton(title: "quit pet", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.font = NSFont(name: "Menlo", size: 10)

        // info first — picker + sound live behind a collapsed settings toggle
        settingsBox.orientation = .vertical
        settingsBox.alignment = .leading
        settingsBox.spacing = 6
        settingsBox.addArrangedSubview(grid)
        settingsBox.addArrangedSubview(soundCheck)
        settingsBox.addArrangedSubview(walkCheck)
        settingsBox.addArrangedSubview(quit)
        settingsBox.isHidden = true
        settingsToggle.isBordered = false
        settingsToggle.attributedTitle = Panel.buttonTitle("settings ▸")
        settingsToggle.target = self
        settingsToggle.action = #selector(toggleSettings(_:))

        for v2 in [title, xpLabel, bar, sep(), chipsRow, sessionScroll,
                   sep(), settingsToggle, settingsBox] {
            stack.addArrangedSubview(v2)
        }
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        panel.contentView = card
    }

    private func sep() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.widthAnchor.constraint(equalToConstant: 332).isActive = true
        return v
    }

    static func buttonTitle(_ s: String) -> NSAttributedString {
        // dark card + default button title color = invisible text; force light
        NSAttributedString(string: s, attributes: [
            .foregroundColor: cFG,
            .font: NSFont(name: "Menlo", size: 10) ?? NSFont.systemFont(ofSize: 10),
        ])
    }

    private func toggleCard(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        if let (st, m, se, n) = lastRefresh {
            refresh(state: st, mode: m, sessions: se, nInput: n)
        }
    }

    @objc private func toggleSettings(_ sender: NSButton) {
        settingsBox.isHidden.toggle()
        settingsToggle.attributedTitle =
            Panel.buttonTitle(settingsBox.isHidden ? "settings ▸" : "settings ▾")
        panel.setContentSize(NSSize(width: 360,
                            height: panel.contentView!.fittingSize.height))
        fitOnScreen()
    }

    // keep the whole panel visible after any resize — growing must never push
    // it off-screen or over the Dock
    func fitOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var o = panel.frame.origin
        let vis = screen.visibleFrame
        o.y = max(vis.minY, min(o.y, vis.maxY - panel.frame.height))
        o.x = max(vis.minX, min(o.x, vis.maxX - panel.frame.width))
        panel.setFrameOrigin(o)
    }

    @objc private func pick(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { onPick?(key) }
    }

    @objc private func soundToggled(_ sender: NSButton) {
        onSound?(sender.state == .on)
    }

    @objc private func walkToggled(_ sender: NSButton) {
        onWalk?(sender.state == .on)
    }

    func refresh(state: [String: Any], mode: String, sessions: [SessionInfo], nInput: Int) {
        lastRefresh = (state, mode, sessions, nInput)
        let xp = totalXP(state)
        var (stage, lo, hi) = stageFor(xp)
        let hatched = (state["hatched"] as? Bool ?? false) || stage != "egg"
        if hatched && stage == "egg" { stage = "hatchling"; lo = 0; hi = 200 }
        let speciesKey = state["species"] as? String ?? "cat"
        let sp = assets.species[speciesKey] ?? assets.species["cat"]!
        let level = min(99, 1 + Int((Double(xp) / 10.0).squareRoot()))
        let crown = stage == "legendary" ? "👑 " : ""
        let name = hatched ? (state["name"] as? String ?? sp.name) : "???"

        title.stringValue = "\(sp.emoji) \(crown)\(name) · Lv.\(level)"
        // stage merged into the xp line — no separate stage row
        if let hi = hi {
            xpLabel.stringValue = hatched
                ? "\(stage) · \(xp) XP · \(hi - xp) to \(stageNext[stage] ?? "?")"
                : "egg · pick a sprite in settings to hatch!"
            let frac = max(0, min(1, Double(xp - lo) / Double(hi - lo)))
            barFill.frame = NSRect(x: 0, y: 0, width: 332 * frac, height: 6)
        } else {
            xpLabel.stringValue = "\(stage) · \(xp) XP · max stage"
            barFill.frame = NSRect(x: 0, y: 0, width: 332, height: 6)
        }

        // colored count chips instead of a single status line
        chipsRow.arrangedSubviews.forEach {
            chipsRow.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        func chip(_ text: String, _ color: NSColor) {
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
            pill.layer?.cornerRadius = 9
            pill.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            l.textColor = color
            l.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(l)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 18),
                l.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                l.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
                l.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            ])
            chipsRow.addArrangedSubview(pill)
        }
        let nWorking = sessions.filter { $0.phase == "working" || $0.phase == "busy" }.count
        let nNeed = sessions.filter { $0.phase == "input" }.count
        let nStalled = sessions.filter { $0.phase == "stalled" }.count
        let nDone = sessions.filter { $0.phase == "ready" }.count
        if nWorking > 0 { chip("\(nWorking) working", cAccent) }
        if nNeed > 0 { chip("\(nNeed) need you", cInput) }
        if nStalled > 0 { chip("\(nStalled) stalled", cStalled) }
        if nDone > 0 { chip("\(nDone) done", cWarn) }
        if chipsRow.arrangedSubviews.isEmpty { chip("all idle", cMuted) }

        // one persistent card per session path — labels update in place, so a
        // refresh never destroys a card mid-click and ages tick every refresh
        let ordered = sessions.sorted { ($0.phase == "idle" ? 1 : 0) < ($1.phase == "idle" ? 1 : 0) }
            .prefix(20)
        let livePaths = Set(ordered.map { $0.path })
        for (path, card) in cards where !livePaths.contains(path) {
            card.removeFromSuperview()
            cards.removeValue(forKey: path)
        }
        var y: CGFloat = 0
        for sess in ordered {
            let card: SessionCard
            if let existing = cards[sess.path] {
                card = existing
            } else {
                card = SessionCard()
                cards[sess.path] = card
                sessionDoc.addSubview(card)
            }
            card.update(sess, open: expanded.contains(sess.path), width: 332)
            card.setFrameOrigin(NSPoint(x: 0, y: y))
            card.onClick = { [weak self] in
                self?.onCardClick?(sess) // per-card ack
                self?.toggleCard(sess.path)
            }
            y += card.frame.height + 8
        }
        if ordered.isEmpty {
            if emptyLabel == nil {
                let l = NSTextField(labelWithString: "no recent sessions")
                l.font = NSFont.systemFont(ofSize: 11); l.textColor = cMuted
                l.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
                sessionDoc.addSubview(l)
                emptyLabel = l
            }
            y = 18
        }
        emptyLabel?.isHidden = !ordered.isEmpty
        // doc height == visible height when the list fits (no phantom 8pt
        // scroll); the trailing 8pt breathing room exists only when actually
        // clamped/scrolling
        let contentH: CGFloat = ordered.isEmpty ? 18 : y - 8
        sessionDoc.frame = NSRect(x: 0, y: 0, width: 332,
                                  height: max(contentH > 300 ? y : contentH, 18))
        sessionHeight.constant = min(contentH, 300)

        soundCheck.state = (state["sound"] as? Bool ?? true) ? .on : .off
        walkCheck.state = (state["walk"] as? Bool ?? true) ? .on : .off
        for (key, b) in pickButtons {
            b.layer?.borderWidth = key == speciesKey ? 2 : 0
            b.layer?.borderColor = cAccent.cgColor
        }
        panel.setContentSize(NSSize(width: 360,
                            height: panel.contentView!.fittingSize.height))
        if panel.isVisible { fitOnScreen() }
    }
}
