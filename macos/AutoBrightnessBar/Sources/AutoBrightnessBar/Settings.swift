// Settings for the bar: where the sun is, how often to look, whether to start at
// login, and what the solar model has learned so far.
//
// The coordinates are the only setting that belongs to the agent rather than to
// this app, and the agent's config is a shell file the user also edits by hand.
// So it is never serialised wholesale: ConfigRewrite edits the one line, the
// candidate is validated by the agent itself, and only then does it replace the
// file atomically. The same discipline as cc-limits, for the same reason - that
// file has comments in it that took an evening to work out.
import AppKit
import SwiftUI
import CoreLocation
import AutoBrightnessCore

// MARK: - The bar's own preferences

struct BarPrefs: Codable {
    var interval: Double = 5

    static let path = NSHomeDirectory() + "/.config/autobrightness/bar.json"

    static func load() -> BarPrefs {
        guard let data = FileManager.default.contents(atPath: path),
              let p = try? JSONDecoder().decode(BarPrefs.self, from: data) else { return BarPrefs() }
        return p
    }
    func save() {
        try? FileManager.default.createDirectory(
            atPath: (BarPrefs.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: BarPrefs.path), options: .atomic)
    }
}

// MARK: - The agent's config

enum AgentConfig {
    static let path = NSHomeDirectory() + "/.config/autobrightness/config"

    static func text() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    static func coords() -> (lat: String, lon: String) {
        var lat = "", lon = ""
        for line in text().components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#") else { continue }
            if t.hasPrefix("SOLAR_LAT=") { lat = value(t) }
            if t.hasPrefix("SOLAR_LON=") { lon = value(t) }
        }
        return (lat, lon)
    }
    private static func value(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return "" }
        var v = String(line[line.index(after: eq)...])
        if let hash = v.firstIndex(of: "#") { v = String(v[..<hash]) }
        return v.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    enum SaveError: LocalizedError {
        case rejected(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let why):    return "The agent refused the new config: \(why)"
            case .cannotWrite(let why): return "Could not write the config: \(why)"
            }
        }
    }

    /// Writes the coordinates, having had the agent read the candidate first.
    static func setCoords(lat: String, lon: String) throws {
        var updated = ConfigRewrite.set(text(), key: "SOLAR_LAT", value: lat)
        updated = ConfigRewrite.set(updated, key: "SOLAR_LON", value: lon)

        let tmp = NSTemporaryDirectory() + "/autobrightness-config-candidate"
        do {
            try updated.write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            throw SaveError.cannotWrite(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // The agent is the authority on its own config: if it cannot compute a
        // sun angle from the candidate, the candidate does not get installed.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agentBinary)
        proc.arguments = ["sun"]
        var env = ProcessInfo.processInfo.environment
        env["AUTOBRIGHTNESS_CONFIG"] = tmp
        proc.environment = env
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        do { try proc.run() } catch {
            throw SaveError.rejected("could not run \(agentBinary)")
        }
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw SaveError.rejected(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SaveError.cannotWrite(error.localizedDescription)
        }
    }
}

// MARK: - What the model has learned

struct ModelRow: Identifiable {
    let id: Int
    let from: Int
    let to: Int
    let nits: Double
    let samples: Int
    let age: TimeInterval
}

enum ModelFile {
    static let path = NSHomeDirectory() + "/.local/state/autobrightness.solar"

    static func rows(binDeg: Int) -> [ModelRow] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let now = Date().timeIntervalSince1970
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 4, let bin = Int(f[0]), let nits = Double(f[1]),
                  let n = Int(f[2]), let epoch = Double(f[3]) else { return nil }
            return ModelRow(id: bin, from: bin * binDeg - 90, to: (bin + 1) * binDeg - 90,
                            nits: nits, samples: n, age: now - epoch)
        }.sorted { $0.from < $1.from }
    }

    static func forget() { try? FileManager.default.removeItem(atPath: path) }
}

// MARK: - Start at login

enum LoginItem {
    static let path = NSHomeDirectory() + "/Library/LaunchAgents/local.autobrightness-bar.plist"

    static var enabled: Bool { FileManager.default.fileExists(atPath: path) }

    static func set(_ on: Bool) {
        if on {
            let binary = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>local.autobrightness-bar</string>
              <key>ProgramArguments</key><array><string>\(binary)</string></array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? plist.write(toFile: path, atomically: true, encoding: .utf8)
            launchctl(["load", path])
        } else {
            launchctl(["unload", path])
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Asking macOS where we are

struct LocationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LocationFetcher: NSObject, CLLocationManagerDelegate, ObservableObject {
    private let manager = CLLocationManager()
    private var completion: ((Result<CLLocationCoordinate2D, LocationFailure>) -> Void)?
    private var timeout: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
    }

    static func statusName(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined:    return "not determined"
        case .restricted:       return "restricted"
        case .denied:           return "denied"
        case .authorizedAlways: return "authorized"
        @unknown default:       return "status \(s.rawValue)"
        }
    }

    func fetch(_ completion: @escaping (Result<CLLocationCoordinate2D, LocationFailure>) -> Void) {
        self.completion = completion

        // An ad-hoc signed app does not reliably get the permission prompt: the
        // client registers with locationd and then nothing happens at all, with
        // no callback to report. Without a deadline the button just sits there,
        // which is exactly how this was found.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            let st = Self.statusName(self.manager.authorizationStatus)
            self.finish(.failure(LocationFailure(
                message: "macOS did not answer (status: \(st)). An ad-hoc signed app "
                       + "often never gets the prompt \u{2014} use the time zone button.")))
        }
        self.timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // the answer arrives in the delegate
        case .denied, .restricted:
            finish(.failure(LocationFailure(
                message: "Location access is \(Self.statusName(manager.authorizationStatus)) "
                       + "for this app in System Settings \u{2192} Privacy & Security \u{2192} Location Services")))
        default:
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorized, .authorizedAlways: m.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationFailure(message: "Location access was declined")))
        default: break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        finish(.success(c))
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // Unbundled builds have no usage description, so CoreLocation refuses
        // outright. Say so rather than spinning.
        finish(.failure(LocationFailure(message: error.localizedDescription)))
    }
    private func finish(_ r: Result<CLLocationCoordinate2D, LocationFailure>) {
        timeout?.cancel()
        timeout = nil
        let c = completion
        completion = nil
        DispatchQueue.main.async { c?(r) }
    }
}

// MARK: - The window

struct SettingsView: View {
    @State private var lat: String = AgentConfig.coords().lat
    @State private var lon: String = AgentConfig.coords().lon
    @State private var interval: Double = BarPrefs.load().interval
    @State private var atLogin: Bool = LoginItem.enabled
    @State private var note: String?
    @State private var noteIsError = false
    @State private var rows: [ModelRow] = []
    @State private var binDeg: Int = 5
    @StateObject private var locator = LocationFetcher()

    var onPrefsChanged: () -> Void

    var body: some View {
        Form {
            Section("Where the sun is") {
                Text("With the lid shut the Mac has no light sensor: the one it has sits in "
                     + "the lid and faces the keyboard. The model needs coordinates to know "
                     + "which hour of which season it is replaying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Latitude") {
                    TextField("55.7558", text: $lat).frame(width: 120)
                }
                LabeledContent("Longitude") {
                    TextField("37.6176", text: $lon).frame(width: 120)
                }
                HStack {
                    Button("Use my time zone") { useTimeZone() }
                    Button("Use my location") { useLocation() }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(noteIsError ? .red : .secondary)
                }
            }

            Section("Bar") {
                LabeledContent("Poll every") {
                    HStack {
                        Slider(value: $interval, in: 2...60, step: 1).frame(width: 160)
                        Text("\(Int(interval)) s").monospacedDigit()
                    }
                }
                Toggle("Start at login", isOn: $atLogin)
                    .onChange(of: atLogin) { on in LoginItem.set(on) }
            }

            Section("What the model has learned") {
                if rows.isEmpty {
                    Text("Nothing yet. The model fills in while the lid is open and the "
                         + "built-in sensor is readable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Table(rows) {
                        TableColumn("Sun") { r in
                            Text("\(r.from)\u{00B0}..\(r.to)\u{00B0}").monospacedDigit()
                        }
                        TableColumn("Learned") { r in
                            Text(AmbientScale().format(r.nits)).monospacedDigit()
                        }
                        TableColumn("Samples") { r in
                            Text("\(r.samples)").monospacedDigit()
                        }
                        TableColumn("Last seen") { r in
                            Text(r.age < 86400 ? "today" : "\(Int(r.age / 86400)) d ago")
                        }
                    }
                    .frame(minHeight: 160)
                    Button("Forget everything learned") {
                        ModelFile.forget()
                        rows = []
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { reload() }
    }

    private func reload() {
        let c = AgentConfig.coords()
        lat = c.lat; lon = c.lon
        rows = ModelFile.rows(binDeg: binDeg)
    }

    /// No prompt, no network, no permission: macOS ships a position for every
    /// time zone in /usr/share/zoneinfo/zone.tab.
    private func useTimeZone() {
        guard let p = TimeZoneCoords.current() else {
            note = "Could not read \(TimeZoneCoords.tabPath)"
            noteIsError = true
            return
        }
        lat = String(format: "%.4f", p.latitude)
        lon = String(format: "%.4f", p.longitude)
        let where_ = p.comment.isEmpty ? p.zone : "\(p.zone), \(p.comment)"
        note = "From your time zone: \(where_). That is the zone's reference city, "
             + "so edit it if you are far from there. Press Save."
        noteIsError = false
    }

    private func useLocation() {
        note = "Asking macOS\u{2026}"
        noteIsError = false
        locator.fetch { result in
            switch result {
            case .success(let c):
                lat = String(format: "%.4f", c.latitude)
                lon = String(format: "%.4f", c.longitude)
                note = "Got it. Press Save to write it into the agent's config."
                noteIsError = false
            case .failure(let why):
                note = why.message
                noteIsError = true
            }
        }
    }

    private func save() {
        var prefs = BarPrefs.load()
        prefs.interval = interval
        prefs.save()
        onPrefsChanged()
        do {
            try AgentConfig.setCoords(lat: lat.trimmingCharacters(in: .whitespaces),
                                      lon: lon.trimmingCharacters(in: .whitespaces))
            note = "Saved to \(AgentConfig.path)"
            noteIsError = false
        } catch {
            note = error.localizedDescription
            noteIsError = true
        }
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    var onPrefsChanged: () -> Void = {}

    func show() {
        if window == nil {
            let view = SettingsView(onPrefsChanged: { [weak self] in self?.onPrefsChanged() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "autobrightness"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
