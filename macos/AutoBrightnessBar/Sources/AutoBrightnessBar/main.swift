// Menu bar indicator for autobrightness.
//
// One gauge next to the clock answering the two questions a closed lid raises:
// what level is being applied, and whether anything actually measured it.
//
//   arc length   - where the ambient value sits on the nits scale, logarithmic
//   arc strength - how much to trust it: full for a live sensor, faded for the
//                  solar model, fainter still for a reading merely held
//   centre dot   - a sensor is reporting right now (filled), the model is
//                  (small), or nothing is (absent)
//   centre square - a level set by hand, which outranks every sensor
//   slash        - paused, the agent is not touching the monitors
//
// All numbers come from `autobrightness --indicator`; this draws them and sends
// back the three commands a person needs in a hurry - manual level, pause, resume.
import AppKit
import CoreLocation
import AutoBrightnessCore

// MARK: - Talking to the agent

let agentBinary: String = {
    let candidates = [
        NSHomeDirectory() + "/.local/bin/autobrightness",
        "/opt/homebrew/bin/autobrightness",
        "/usr/local/bin/autobrightness",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
}()

enum Agent {
    /// Runs the agent and hands back stdout. Off the main thread: a tick that
    /// catches the bus busy can take a moment, and the menu must not freeze.
    static func run(_ args: [String], capture: Bool = true,
                    completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: agentBinary)
            proc.arguments = args
            let out = Pipe()
            proc.standardOutput = capture ? out : Pipe()
            proc.standardError = Pipe()
            do { try proc.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = capture ? out.fileHandleForReading.readDataToEndOfFile() : nil
            proc.waitUntilExit()
            DispatchQueue.main.async { completion(proc.terminationStatus == 0 ? data : nil) }
        }
    }

    static func snapshot(_ completion: @escaping (Snapshot?) -> Void) {
        run(["--indicator"]) { data in
            guard let data, let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                completion(nil); return
            }
            completion(snap)
        }
    }

    static func command(_ args: [String], then: @escaping () -> Void) {
        run(args, capture: false) { _ in then() }
    }
}

// MARK: - The gauge

let scale = AmbientScale()

func trustAlpha(_ source: AmbientSource) -> CGFloat {
    switch source {
    case .als, .sensor, .manual: return 1.0
    case .solar: return 0.75
    case .hold:  return 0.5
    case .none:  return 0.35
    }
}

// The gauge itself, drawn into whatever rectangle it is given. Kept apart from
// NSImage so the same code can be rendered straight into a bitmap for a look at
// it; an NSImage drawing handler is lazy and renders blank when pulled through
// cgImage(forProposedRect:) in a process with no window on screen.
func drawGauge(_ snap: Snapshot?, in rect: CGRect) {
    let source = AmbientSource(snap?.ambient.source ?? "none")
    let alpha = trustAlpha(source)
    let diameter = min(rect.width, rect.height)
    let box = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                     width: diameter, height: diameter)
    let stroke = diameter * 0.17
    let radius = (diameter - stroke) / 2
    let centre = CGPoint(x: box.midX, y: box.midY)
    let ink = NSColor.labelColor

    // the track, so an empty gauge still reads as a gauge
    let track = NSBezierPath()
    track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = stroke
    ink.withAlphaComponent(0.25).setStroke()
    track.stroke()

    if let nits = snap?.ambient.nits {
        let sweep = CGFloat(scale.position(nits)) * 360
        if sweep > 0.5 {
            let arc = NSBezierPath()
            if sweep >= 359.5 {
                arc.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            } else {
                // butt caps: a round cap at one percent paints a visible dot,
                // which would show more light than is actually applied
                arc.appendArc(withCenter: centre, radius: radius, startAngle: 90,
                              endAngle: 90 - sweep, clockwise: true)
            }
            arc.lineCapStyle = .butt
            arc.lineWidth = stroke
            // A held reading is a measurement that has stopped being checked, so
            // the arc is broken rather than merely faint: fading alone put it too
            // close to the track and to "no source at all".
            if source == .hold {
                var dash: [CGFloat] = [stroke * 1.1, stroke * 0.9]
                arc.setLineDash(&dash, count: 2, phase: 0)
            }
            ink.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
    }

    // the centre says where the number came from
    switch source {
    case .manual:
        let s = diameter * 0.30
        ink.setFill()
        NSBezierPath(rect: CGRect(x: centre.x - s / 2, y: centre.y - s / 2,
                                  width: s, height: s)).fill()
    case .als, .sensor:
        let r = diameter * 0.17
        ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - r, y: centre.y - r,
                                    width: r * 2, height: r * 2)).fill()
    case .solar:
        // hollow, against the filled dot of a live sensor: the model is a
        // reconstruction, and that difference is the one worth seeing at a glance
        let r = diameter * 0.15
        let ring = NSBezierPath(ovalIn: CGRect(x: centre.x - r, y: centre.y - r,
                                               width: r * 2, height: r * 2))
        ring.lineWidth = diameter * 0.08
        ink.withAlphaComponent(0.85).setStroke()
        ring.stroke()
    case .hold, .none:
        break
    }

    if snap?.paused == true {
        let slash = NSBezierPath()
        slash.move(to: CGPoint(x: box.minX + stroke / 2, y: box.minY + stroke / 2))
        slash.line(to: CGPoint(x: box.maxX - stroke / 2, y: box.maxY - stroke / 2))
        slash.lineWidth = max(1.5, diameter * 0.12)
        slash.lineCapStyle = .round
        ink.setStroke()
        slash.stroke()
    }
}

func makeIcon(_ snap: Snapshot?) -> NSImage {
    // height follows the real menu bar thickness: on a Mac with a notch it is taller
    let height = max(18, NSStatusBar.system.thickness - 2)
    let diameter = height - 5
    let pad: CGFloat = 1.5
    let width = pad * 2 + diameter

    // drawingHandler rather than a bitmap: AppKit redraws it for the screen's
    // backing scale and for the current light or dark menu bar
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        drawGauge(snap, in: CGRect(x: pad, y: (rect.height - diameter) / 2,
                                   width: diameter, height: diameter))
        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - The manual slider, as a menu row

final class SliderRow: NSView {
    let slider = NSSlider()
    let label = NSTextField(labelWithString: "")
    var onChange: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))
        label.font = .menuFont(ofSize: 12)
        label.textColor = .labelColor
        label.frame = NSRect(x: 14, y: 26, width: width - 28, height: 16)
        addSubview(label)

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.frame = NSRect(x: 14, y: 4, width: width - 28, height: 20)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Dragging sends a command per step, and each one shells out to the agent.
    // So the label follows the finger and the command waits for a pause.
    private var debounce: DispatchWorkItem?

    @objc private func moved() {
        let nits = scale.nits(slider.doubleValue)
        onChange?(nits)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onCommit?(nits) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

// MARK: - The bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var latest: Snapshot?
    private var prefs = BarPrefs.load()
    private lazy var settings = SettingsWindowController()
    private var sliderRow: SliderRow?
    private var pendingManual: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = makeIcon(nil)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild()
        refresh()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: prefs.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        Agent.snapshot { [weak self] snap in
            guard let self else { return }
            if let snap { self.latest = snap }
            self.statusItem.button?.image = makeIcon(self.latest)
            self.statusItem.button?.toolTip = self.tooltip()
            self.rebuild()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func tooltip() -> String {
        guard let snap = latest else { return "autobrightness: the agent did not answer" }
        let source = AmbientSource(snap.ambient.source)
        guard let nits = snap.ambient.nits else { return "autobrightness: no ambient source" }
        return "\(scale.format(nits)), \(source.label)"
    }

    // MARK: menu

    private func item(_ title: String, enabled: Bool = false,
                      action: Selector? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = action == nil ? nil : self
        it.isEnabled = enabled
        return it
    }

    private func rebuild() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        guard let snap = latest else {
            menu.addItem(item("The agent did not answer"))
            menu.addItem(item("Expected it at \(agentBinary)"))
            addTail(menu)
            return
        }
        if let c = snap.contract, c != requiredContract {
            menu.addItem(item("Agent contract \(c), this app expects \(requiredContract)"))
            menu.addItem(item("Reinstall: ./install.sh"))
            menu.addItem(.separator())
        }

        let source = AmbientSource(snap.ambient.source)
        if let nits = snap.ambient.nits {
            menu.addItem(item("\(scale.format(nits)) \u{2014} \(source.label)"))
        } else {
            menu.addItem(item("No ambient source \u{2014} monitors left alone"))
        }
        if source == .hold, snap.ambient.age > 0 {
            menu.addItem(item("   held for \(humanAge(snap.ambient.age))"))
        }

        if snap.model.on {
            var line = "Model: \(snap.model.bins) of \(snap.model.bins_total) buckets"
            if let e = snap.ambient.elevation {
                line += String(format: ", sun %.1f\u{00B0}", e)
            }
            menu.addItem(item(line))
        } else {
            menu.addItem(item("Solar model off \u{2014} no coordinates set"))
        }

        menu.addItem(.separator())
        for d in snap.displays {
            menu.addItem(displayItem(d))
        }

        menu.addItem(.separator())
        let row = SliderRow(width: 260)
        let shown = pendingManual ?? snap.manual?.nits ?? snap.ambient.nits ?? 20
        row.slider.doubleValue = scale.position(shown)
        row.label.stringValue = snap.manual == nil && pendingManual == nil
            ? "Set a level by hand"
            : "By hand: \(scale.format(shown))"
        row.onChange = { [weak self, weak row] nits in
            self?.pendingManual = nits
            row?.label.stringValue = "By hand: \(scale.format(nits))"
        }
        row.onCommit = { [weak self] nits in
            Agent.command(["manual", String(format: "%.1f", nits)]) { self?.refresh() }
        }
        let rowItem = NSMenuItem()
        rowItem.view = row
        menu.addItem(rowItem)
        sliderRow = row

        if snap.manual != nil || pendingManual != nil {
            menu.addItem(item("Back to automatic", enabled: true, action: #selector(clearManual)))
        }
        menu.addItem(item(snap.paused ? "Resume" : "Pause",
                          enabled: true,
                          action: snap.paused ? #selector(resume) : #selector(pause)))
        addTail(menu)
    }

    private func displayItem(_ d: DisplayInfo) -> NSMenuItem {
        let name = d.name.count > 14 ? String(d.name.prefix(13)) + "\u{2026}" : d.name
        var text = String(format: "%-14@", name as NSString)
        if !d.connected {
            text += "not connected"
        } else {
            func pair(_ a: Int?, _ b: Int?) -> String {
                guard let a else { return "?" }
                return b == nil ? "\(a)" : "\(a)/\(b!)"
            }
            let target = d.target_lum == nil ? "\u{2014}" : pair(d.target_lum, d.target_blue)
            text += "\(target) \u{2192} \(pair(d.lum, d.blue))"
            if d.mode == "gamma" { text += "  (gamma)" }
        }
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        it.isEnabled = false
        return it
    }

    private func addTail(_ menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(item("Settings\u{2026}", enabled: true, action: #selector(openSettings)))
        menu.addItem(item("Quit", enabled: true, action: #selector(quit)))
    }

    private func humanAge(_ sec: Int) -> String {
        if sec < 90 { return "\(sec)s" }
        if sec < 5400 { return "\(sec / 60) min" }
        if sec < 172800 { return "\(sec / 3600) h" }
        return "\(sec / 86400) d"
    }

    // MARK: actions

    @objc private func clearManual() {
        pendingManual = nil
        Agent.command(["manual", "off"]) { [weak self] in self?.refresh() }
    }
    @objc private func pause() {
        Agent.command(["pause"]) { [weak self] in self?.refresh() }
    }
    @objc private func resume() {
        Agent.command(["resume"]) { [weak self] in self?.refresh() }
    }
    @objc private func openSettings() {
        settings.onPrefsChanged = { [weak self] in
            self?.prefs = BarPrefs.load()
            self?.restartTimer()
            self?.refresh()
        }
        settings.show()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

// Renders the gauge to a PNG instead of running, at a given scale. The menu bar
// cannot be screenshotted without Screen Recording permission, and an 18 pixel
// gauge has to be looked at to be judged.
//
//   AutoBrightnessBar --render-icon out.png <source> <nits> [paused|live] [zoom] [dark]
func renderIcon(_ args: [String]) -> Int32 {
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("usage: --render-icon out.png <source> <nits> [paused|live] [zoom] [dark]\n".utf8))
        return 2
    }
    let path = args[1], source = args[2]
    let nits = Double(args[3])
    let paused = args.count > 4 && args[4] == "paused"
    let darkMode = args.contains("dark")
    let zoom = args.count > 5 ? (Double(args[5]) ?? 1) : 1

    let json = """
    {"contract":1,"paused":\(paused),
     "ambient":{"nits":\(nits.map { String($0) } ?? "null"),"source":"\(source)","age":0,
                "slider":null,"elevation":null},
     "model":{"bins":0,"bins_total":36,"bin_deg":5,"on":false},
     "manual":\(source == "manual" ? "{\"nits\":\(nits ?? 0)}" : "null"),"displays":[]}
    """
    var snap: Snapshot?
    do {
        snap = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    } catch {
        FileHandle.standardError.write(Data("render: \(error)\n\(json)\n".utf8))
        return 1
    }
    let side = Int(18 * zoom)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return 1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // labelColor is a dynamic colour: with no appearance in effect it resolves to
    // nothing at all and the gauge comes out blank. The menu bar supplies one; a
    // bitmap context has to be told.
    let appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    appearance.performAsCurrentDrawingAppearance {
        // white for the light menu bar, near-black for the dark one
        (darkMode ? NSColor(white: 0.1, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        drawGauge(snap, in: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    try? png.write(to: URL(fileURLWithPath: path))
    return 0
}

// Every state the gauge has, side by side, on both menu bar colours. One image
// is the only way to judge whether the states are still distinguishable at the
// size they are actually seen at.
//
//   AutoBrightnessBar --render-strip out.png [zoom]
func renderStrip(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { return 2 }
    let path = args[1]
    let zoom = args.count > 2 ? (Double(args[2]) ?? 8) : 8
    let cell = Int(18 * zoom)

    let states: [(String, Double?, Bool)] = [
        ("als", 400, false), ("als", 137, false), ("als", 2, false),
        ("solar", 60, false), ("hold", 20, false),
        ("manual", 300, false), ("none", nil, false), ("als", 137, true),
    ]
    let width = cell * states.count, height = cell * 2

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return 1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    for (row, dark) in [(0, true), (1, false)] {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { continue }
        appearance.performAsCurrentDrawingAppearance {
            (dark ? NSColor(white: 0.1, alpha: 1) : NSColor.white).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: row * cell, width: width, height: cell)).fill()
            for (i, st) in states.enumerated() {
                let json = """
                {"contract":1,"paused":\(st.2),
                 "ambient":{"nits":\(st.1.map { String($0) } ?? "null"),"source":"\(st.0)",
                            "age":0,"slider":null,"elevation":null},
                 "model":{"bins":0,"bins_total":36,"bin_deg":5,"on":false},
                 "manual":null,"displays":[]}
                """
                let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
                drawGauge(snap, in: CGRect(x: Double(i * cell) + zoom, y: Double(row * cell) + zoom,
                                           width: Double(cell) - 2 * zoom,
                                           height: Double(cell) - 2 * zoom))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    try? png.write(to: URL(fileURLWithPath: path))
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--render-icon" {
    exit(renderIcon(args))
}
if args.first == "--render-strip" {
    exit(renderStrip(args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
