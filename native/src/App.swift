// SessionPet — app delegate: window setup, event spool, the poll/animation
// tick, and sounds (with drop-in sound packs).

import AppKit
import Foundation

// two pet sounds, both overridable from state.json (sound packs):
//   "soundReady" — turn finished (default Glass)
//   "soundInput" — an agent needs you (default Ping)
// values are absolute paths or filenames resolved against sounds/; a missing
// or unreadable file silently falls back to the system default.
enum SoundKind { case ready, input }

func soundPath(_ kind: SoundKind, _ state: [String: Any]) -> String {
    let (key, fallback) = kind == .ready
        ? ("soundReady", "/System/Library/Sounds/Glass.aiff")
        : ("soundInput", "/System/Library/Sounds/Ping.aiff")
    guard let v = state[key] as? String, !v.isEmpty else { return fallback }
    let p = v.hasPrefix("/") ? v : "\(soundsDir)/\(v)"   // relative → sounds/
    return FileManager.default.fileExists(atPath: p) ? p : fallback
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: PetView!
    var petPanel = Panel()
    var lastPoll = 0.0, lastSound = 0.0, lastPing = 0.0
    var realerts: [String: (key: String, count: Int, lastAt: Double)] = [:]
    var evOffset: UInt64 = 0, evPrimed = false
    var notif: [String: (Double, String)] = [:]
    var prevPhases: [String: String] = [:]
    // path → snippet acked by clicking that session's card; keyed by snippet
    // (stable per turn) so post-turn housekeeping writes don't re-nag
    var acked: [String: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scale = CGFloat(min(12, max(3,
            CommandLine.arguments.dropFirst().compactMap { Int($0) }.first ?? 5)))
        let w = 18 * scale, h = 23 * scale
        view = PetView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.scale = scale
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - w - 30,
                                          y: screen.visibleFrame.minY + 40))
        }
        window.makeKeyAndOrderFront(nil)

        view.onClick = { [weak self] in self?.togglePanel() }
        petPanel.onPick = { [weak self] key in
            var st = loadState()
            st["species"] = key
            st["hatched"] = true
            st.removeValue(forKey: "name")
            saveState(st)
            self?.view.state = st
            self?.refreshPanel()
        }
        petPanel.onCardClick = { [weak self] sess in
            // clicking a card = you saw that session (per-card ack)
            self?.acked[sess.path] = ackKey(sess)
        }
        petPanel.onSound = { [weak self] on in
            var st = loadState(); st["sound"] = on; saveState(st)
            self?.view.state = st
        }
        view.onToggleSound = { [weak self] in
            var st = loadState()
            st["sound"] = !(st["sound"] as? Bool ?? true)
            saveState(st)
            self?.view.state = st
        }

        // displays changed (unplugged, resolution switch) — keep the pet visible
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.clampToScreen() }

        // popover behavior: any click outside the panel or the pet dismisses it
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.dismissPanelIfOutside()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] ev in self?.dismissPanelIfOutside(); return ev
        }

        // .common mode: scrolling/menu tracking must not freeze the animation
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func clampToScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var o = window.frame.origin
        o.x = max(vis.minX, min(o.x, vis.maxX - window.frame.width))
        o.y = max(vis.minY, min(o.y, vis.maxY - window.frame.height))
        window.setFrameOrigin(o)
    }

    func dismissPanelIfOutside() {
        guard petPanel.panel.isVisible else { return }
        let loc = NSEvent.mouseLocation
        // clicks on the pet itself keep toggle semantics; panel clicks are its buttons
        if !petPanel.panel.frame.contains(loc) && !window.frame.contains(loc) {
            petPanel.panel.orderOut(nil)
        }
    }

    func togglePanel() {
        if petPanel.panel.isVisible {
            petPanel.panel.orderOut(nil)
        } else {
            refreshPanel()
            let pf = petPanel.panel.frame, wf = window.frame
            // place against the screen the PET is on, not whichever is main
            let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var x = wf.minX - pf.width - 10
            if x < vis.minX { x = wf.maxX + 10 }
            petPanel.panel.setFrameOrigin(NSPoint(x: x, y: max(vis.minY, wf.minY)))
            petPanel.panel.orderFront(nil)
            petPanel.fitOnScreen()
        }
    }

    func refreshPanel() {
        let nInput = view.sessions.filter { $0.phase == "input" }.count
        petPanel.refresh(state: view.state, mode: view.mode,
                         sessions: view.sessions, nInput: nInput)
    }

    func readEvents() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: eventsPath),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            if !evPrimed {
                // no spool at launch = nothing stale to skip; whatever appears
                // later is fresh and must be parsed from byte 0
                evPrimed = true
                evOffset = 0
            }
            return
        }
        if !evPrimed {
            // first read after launch: skip everything already in the file —
            // stale notifications must never replay as fresh
            evPrimed = true
            evOffset = size
            return
        }
        if size < evOffset { evOffset = 0 }
        if size == evOffset { return }
        guard let fh = FileHandle(forReadingAtPath: eventsPath) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: evOffset)
        guard let data = try? fh.readToEnd() else { return }
        // consume only up to the last complete line — advancing past a
        // half-appended line would drop that notification forever
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNL]
        evOffset += UInt64(complete.count)
        let text = String(decoding: complete, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let ev = json(Data(line.utf8)),
                  ev["hook_event_name"] as? String == "Notification" else { continue }
            let path = ev["transcript_path"] as? String ?? ""
            notif[path] = (Date().timeIntervalSince1970,
                           ev["message"] as? String ?? "needs your attention")
        }
        if size > 262_144, evOffset == size {
            // keep the hook log from growing forever — but only truncate when
            // we consumed everything AND nothing new landed since our stat,
            // otherwise a notification appended mid-truncate would be lost
            let cur = (try? FileManager.default.attributesOfItem(atPath: eventsPath))?[.size]
            if (cur as? NSNumber)?.uint64Value == size {
                try? Data().write(to: URL(fileURLWithPath: eventsPath))
                evOffset = 0
            }
        }
    }

    func tick() {
        let now = Date().timeIntervalSince1970
        if now - lastPoll > 1.0 {
            lastPoll = now
            readEvents()
            var sessions = scanSessions()
            for (i, s) in sessions.enumerated() {
                if let n = notif[s.path], n.0 > now - s.age,
                   s.phase != "ready" && s.phase != "idle" {
                    sessions[i] = SessionInfo(path: s.path, age: s.age, phase: "input",
                                              doing: String(n.1.prefix(44)), provider: s.provider,
                                              ctx: s.ctx, snippet: s.snippet, label: s.label,
                                              cwd: s.cwd, project: s.project)
                } else if s.phase == "ready", acked[s.path] == ackKey(s) {
                    // acknowledged and same turn since → plain done, no nagging
                    sessions[i].phase = "idle"
                    sessions[i].doing = "done"
                }
            }
            let phases = Dictionary(uniqueKeysWithValues: sessions.map { ($0.path, $0.phase) })
            var state = loadState()
            for (path, ph) in phases {
                let prev = prevPhases[path]
                if petLogEnabled, prev != ph {
                    petLog("\((path as NSString).lastPathComponent) \(prev ?? "-")->\(ph)")
                }
                if ph == "input" && prev != nil && prev != "input" {
                    view.alertUntil = now + 5
                    playSound(.input, state: state, now: now)
                } else if (prev == "working" || prev == "busy" || prev == "stalled")
                            && ph == "ready" {
                    // stalled counts too: a long-silent session that finally
                    // finishes must still ding and bank XP
                    view.alertUntil = now + 5
                    playSound(.ready, state: state, now: now)
                    var bank = state["sessions"] as? [String: Any] ?? [:]
                    bank["window"] = ((bank["window"] as? NSNumber)?.intValue ?? 0) + 5
                    state["sessions"] = bank
                    saveState(state)
                }
            }
            prevPhases = phases
            // pager pattern: while a needs-input session stays unacknowledged,
            // re-ping every 45s (max 3 extra) — one chime is easy to miss
            // under YouTube/music; acking the card or answering stops it
            for s in sessions where s.phase == "input" && acked[s.path] != ackKey(s) {
                let key = ackKey(s)
                var r = realerts[s.path] ?? (key: key, count: 0, lastAt: now)
                if r.key != key { r = (key: key, count: 0, lastAt: now) }
                if r.count < 3, now - r.lastAt > 45 {
                    r.count += 1; r.lastAt = now
                    view.alertUntil = now + 5
                    lastPing = 0  // re-alert bypasses the debounce window
                    playSound(.input, state: state, now: now)
                }
                realerts[s.path] = r
            }
            let nActive = phases.values.filter { $0 == "working" || $0 == "busy" }.count
            let nInput = phases.values.filter { $0 == "input" }.count
            let nReady = phases.values.filter { $0 == "ready" }.count
            let nStalled = phases.values.filter { $0 == "stalled" }.count
            view.mode = nInput > 0 ? "waiting" : (nActive > 0 ? "working"
                : (nReady > 0 || nStalled > 0 ? "waiting" : "sleeping"))
            view.needsAttention = sessions.contains {
                ($0.phase == "ready" || $0.phase == "input" || $0.phase == "stalled")
                    && acked[$0.path] != ackKey($0)
            }
            view.sessions = sessions
            view.state = loadState()
            if petPanel.panel.isVisible { refreshPanel() }
        }
        view.frameCount += 1
        view.needsDisplay = true
    }

    func playSound(_ kind: SoundKind, state: [String: Any], now: Double) {
        guard state["sound"] as? Bool ?? true else { return }
        // the needs-input ping has its own debounce clock — a ready ding
        // moments earlier must never mask the more urgent sound
        if kind == .input {
            guard now - lastPing > soundDebounce else { return }
            lastPing = now
        } else {
            guard now - lastSound > soundDebounce else { return }
            lastSound = now
        }
        let path = soundPath(kind, state)
        petLog("sound \((path as NSString).lastPathComponent)")
        // volume: needs-input must cut through video/music (afplay -v gain);
        // configurable via state.json soundVolume (default 1.6 input, 1.0 ready)
        let userVol = (state["soundVolume"] as? NSNumber)?.doubleValue
        let vol = userVol ?? (kind == .input ? 1.6 : 1.0)
        afplay(path, volume: vol)
        if kind == .input {
            // double-ping pattern: repetition beats loudness through masking
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.afplay(path, volume: vol)
            }
        }
    }

    private func afplay(_ path: String, volume: Double) {
        // NSSound fire-and-forget gets released before audio starts; afplay
        // is what the Python pet used and it just works
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", String(format: "%.2f", min(max(volume, 0.1), 3.0)), path]
        try? p.run()
    }
}
