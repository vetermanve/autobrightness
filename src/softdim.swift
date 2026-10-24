// Software dimming through the display's gamma table, for monitors that do not
// answer DDC/CI - typically panels on the built-in HDMI port of an Apple Silicon
// Mac, where DDC has been broken since M1.
//
// This scales the signal, not the backlight. Black stays exactly where it was, so
// contrast drops, no power is saved and the backlight ages at the same rate. It is
// a fallback, not an equal to DDC.
//
// macOS reverts a gamma table when the process that set it exits, so this cannot
// run as a one-shot. The daemon mode stays resident and owns the gamma.
//
// The daemon takes no light readings of its own. The agent resolves ambient once
// per tick - built-in sensor, solar model, hold, whatever won - and leaves the
// result in a state file; this reads that file. Two readers of the same sensor
// drifted apart in exactly the situation that matters: with the lid shut the
// agent held its last value while this one saw zero nits and drove to the floor.
//
//   softdim get <name>
//   softdim set <name> <0-100>
//   softdim daemon <interval_ms> <panel_gamma> <name:lum_min:lum_max:panel_nits> ...
//   softdim steps <name> <from> <to> <step> <seconds>   - calibration sweep
//   softdim follow <name> <file>   - hold whatever value the file contains
import CoreGraphics
import AppKit
import Foundation

let CAP = 256
let STATE = (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
let AMBIENT_FILE = (STATE as NSString).appendingPathComponent("autobrightness.ambient")
let MAP_FILE = (STATE as NSString).appendingPathComponent("autobrightness.displays")
let PAUSE_FILE = (STATE as NSString).appendingPathComponent("autobrightness.paused")

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ---- finding a display ------------------------------------------------------
// NSScreen.screens is a per-process snapshot: it refreshes only when an app's
// run loop processes a display-reconfiguration notification. A daemon with no run
// loop therefore keeps handing out display ids that died the first time a monitor
// slept or was replugged, and every gamma write after that goes nowhere - with no
// error, because CGSetDisplayTransferByTable does not report an unknown id. Found
// after thirteen days of a daemon that believed it was dimming.
//
// So resolve through the UUID instead. It is derived from the panel itself, so it
// survives replugging, and CoreGraphics looks it up live. The agent writes the
// uuid-to-name map each tick, from `m1ddc display list`.
func mappedDisplays() -> [(uuid: String, name: String)] {
    guard let text = try? String(contentsOfFile: MAP_FILE, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard f.count == 2 else { return nil }
        return (uuid: f[0], name: f[1])
    }
}
func screenDisplays() -> [(id: CGDirectDisplayID, name: String)] {
    NSScreen.screens.compactMap { s in
        guard let v = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return (id: CGDirectDisplayID(v.uint32Value), name: s.localizedName)
    }
}
func find(_ needle: String) -> CGDirectDisplayID? {
    // CGDisplayGetDisplayIDFromUUID aborts on an assertion (CGS_REQUIRE_INIT) in a
    // process that has not talked to the window server yet. Any display call primes
    // it; this is the cheapest one.
    _ = CGMainDisplayID()
    for e in mappedDisplays() where e.name.contains(needle) {
        guard let cf = CFUUIDCreateFromString(nil, e.uuid as CFString) else { continue }
        let id = CGDisplayGetDisplayIDFromUUID(cf)
        if id != 0 && CGDisplayIsOnline(id) != 0 { return id }
    }
    // No map yet - the agent has not ticked since install. A fresh process still
    // has a correct NSScreen list, which is enough for the one-shot commands.
    return screenDisplays().first(where: { $0.name.contains(needle) })?.id
}

// ---- the gamma table --------------------------------------------------------
func apply(_ id: CGDirectDisplayID, _ percent: Double) {
    let s = CGGammaValue(max(0, min(100, percent)) / 100.0)
    var r = [CGGammaValue](repeating: 0, count: CAP)
    for i in 0..<CAP { r[i] = CGGammaValue(Float(i) / Float(CAP - 1)) * s }
    var g = r, b = r
    _ = CGSetDisplayTransferByTable(id, UInt32(CAP), &r, &g, &b)
}
func current(_ id: CGDirectDisplayID) -> Double? {
    var r = [CGGammaValue](repeating: 0, count: CAP), g = r, b = r
    var cnt: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, UInt32(CAP), &r, &g, &b, &cnt) == .success, cnt > 1 else { return nil }
    return Double(r[Int(cnt) - 1]) * 100.0
}

// ---- ambient ----------------------------------------------------------------
// "nits source epoch", written by the agent every tick.
func ambient() -> (nits: Double, source: String, epoch: Double)? {
    guard let text = try? String(contentsOfFile: AMBIENT_FILE, encoding: .utf8) else { return nil }
    let f = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
    guard f.count >= 3, let nits = Double(f[0]), let epoch = Double(f[2]) else { return nil }
    return (nits: nits, source: f[1], epoch: epoch)
}

let a = CommandLine.arguments
guard a.count >= 2 else { print("softdim get|set|daemon|steps|follow ..."); exit(2) }

switch a[1] {
case "get":
    guard a.count >= 3, let id = find(a[2]), let v = current(id) else { exit(1) }
    print(String(format: "%.0f", v))

case "set":
    guard a.count >= 4, let id = find(a[2]), let v = Double(a[3]) else { exit(2) }
    apply(id, v)

case "daemon":
    guard a.count >= 5, let intervalMs = Double(a[2]), let panelGamma = Double(a[3]), panelGamma > 0
    else { exit(2) }
    struct Target {
        let name: String, lo: Double, hi: Double, nits: Double
        var applied: Double
    }
    var targets = a[4...].compactMap { spec -> Target? in
        let f = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, let lo = Double(f[1]), let hi = Double(f[2]), let nits = Double(f[3]),
              nits > 0 else { return nil }
        return Target(name: f[0], lo: lo, hi: hi, nits: nits, applied: -1)
    }
    guard !targets.isEmpty else { err("daemon: no usable targets in \(Array(a[4...]))"); exit(2) }
    err("softdim daemon: \(targets.map { "\($0.name) \($0.lo)-\($0.hi) at \($0.nits) nits" })")

    // An ambient value this old means the agent is not ticking - it died, or it
    // found no source it trusts. Keep holding the last computed level rather than
    // drive to a floor on the strength of a stale number.
    let staleAfter = max(30.0, intervalMs / 1000.0 * 4)
    var warnedStale = false, lastSource = ""

    while true {
        let paused = FileManager.default.fileExists(atPath: PAUSE_FILE)
        // While paused the daemon stops touching the gamma table entirely rather
        // than holding its last value, so another process - a calibration sweep,
        // say - can own the display.
        if paused {
            for i in targets.indices { targets[i].applied = -1 }
            Thread.sleep(forTimeInterval: intervalMs / 1000.0)
            continue
        }

        let amb = ambient()
        let age = amb.map { Date().timeIntervalSince1970 - $0.epoch } ?? .infinity
        let fresh = amb != nil && age <= staleAfter
        if !fresh && !warnedStale {
            err("ambient is \(amb == nil ? "missing" : "\(Int(age))s old"), holding the last level")
            warnedStale = true
        }
        if fresh {
            warnedStale = false
            if amb!.source != lastSource {
                err("ambient source: \(amb!.source)")
                lastSource = amb!.source
            }
        }

        for i in targets.indices {
            guard let id = find(targets[i].name) else { targets[i].applied = -1; continue }

            // Re-apply if the display was reconfigured and dropped our table.
            let live = current(id) ?? -1
            var want = targets[i].applied

            if fresh {
                // The gamma table scales the ENCODED signal, and the panel then
                // raises it to its own gamma. Scaling by 0.56 therefore emits about
                // 0.56^2.2 = 0.27 of full light, not 0.56 - which is why a naive
                // linear scale came out roughly twice too dark. Undo the panel
                // curve so the multiplier lands on the luminance we actually want.
                let ratio = max(0.0, min(1.0, amb!.nits / targets[i].nits))
                want = min(targets[i].hi, max(targets[i].lo, 100.0 * pow(ratio, 1.0 / panelGamma)))
            } else if want < 0 {
                // Nothing applied yet and nothing to compute from: leave the
                // display alone instead of picking a number out of the air.
                continue
            }

            var from = targets[i].applied
            if from < 0 || abs(live - from) > 2 { from = live < 0 ? want : live }
            if abs(want - from) >= 1 {
                let steps = max(1, Int(abs(want - from) * 2))
                for s in 1...steps {
                    apply(id, from + (want - from) * Double(s) / Double(steps))
                    Thread.sleep(forTimeInterval: 0.008)
                }
            }
            apply(id, want)
            targets[i].applied = want
        }
        Thread.sleep(forTimeInterval: intervalMs / 1000.0)
    }

case "follow":
    // Holds the value written into a file, re-reading it a few times a second.
    // Needed because macOS drops the gamma table when the setter exits, so manual
    // calibration cannot be done with one-shot writes.
    guard a.count >= 4, let id = find(a[2]) else { exit(2) }
    let path = a[3]
    setvbuf(stdout, nil, _IONBF, 0)
    var last = -1.0
    while true {
        if let txt = try? String(contentsOfFile: path, encoding: .utf8),
           let v = Double(txt.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if v != last { print("гамма \(Int(v))"); last = v }
            apply(id, v)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

case "steps":
    // Calibration sweep. The process has to stay alive for the whole sweep:
    // macOS drops the gamma table the moment the setter exits.
    guard a.count >= 7, let id = find(a[2]),
          let from = Double(a[3]), let to = Double(a[4]),
          let step = Double(a[5]), let secs = Double(a[6]), step > 0 else { exit(2) }
    setvbuf(stdout, nil, _IONBF, 0)
    var v = from, n = 0
    while (from <= to && v <= to) || (from > to && v >= to) {
        n += 1
        apply(id, v)
        print("вариант \(n): гамма \(Int(v))")
        Thread.sleep(forTimeInterval: secs)
        v += (from <= to ? step : -step)
    }
    print("перебор закончен, держу последнее значение")
    while true { apply(id, v - (from <= to ? step : -step)); Thread.sleep(forTimeInterval: 2) }

default: exit(2)
}
