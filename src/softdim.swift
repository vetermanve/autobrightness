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
//   softdim get <name>
//   softdim set <name> <0-100>
//   softdim daemon <interval_ms> <panel_nits> <panel_gamma> <name:lum_min:lum_max> ...
//   softdim steps <name> <from> <to> <step> <seconds>   - calibration sweep
//   softdim follow <name> <file>   - hold whatever value the file contains
import CoreGraphics
import AppKit
import Foundation
import IOKit

let CAP = 256

func displays() -> [CGDirectDisplayID: String] {
    Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
        guard let v = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return (CGDirectDisplayID(v.uint32Value), s.localizedName)
    })
}
func find(_ needle: String) -> CGDirectDisplayID? {
    displays().first(where: { $0.value.contains(needle) })?.key
}
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

// Actual luminance of the built-in panel, in nits. The brightness slider is badly
// nonlinear - slider 0.10 is about 1.5 nits against 400 at 1.00 - so matching an
// external by slider percentage leaves it roughly thirty times too bright in a
// dark room. The built-in framebuffer is the one with no Transport property.
func builtinNits() -> Double? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOMobileFramebufferShim"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        if IORegistryEntryCreateCFProperty(svc, "Transport" as CFString, kCFAllocatorDefault, 0) != nil { continue }
        guard IORegistryEntryCreateCFProperty(svc, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0) != nil
        else { continue }
        guard let lv = IORegistryEntryCreateCFProperty(svc, "IOMFBBrightnessLevel" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { continue }
        return lv.doubleValue / 65536.0
    }
    return nil
}
func interp(_ x: Double, _ xl: Double, _ xh: Double, _ yl: Double, _ yh: Double) -> Double {
    let t = min(1, max(0, (x - xl) / (xh - xl)))
    return yl + t * (yh - yl)
}

let a = CommandLine.arguments
guard a.count >= 2 else { print("softdim get|set|daemon ..."); exit(2) }

switch a[1] {
case "get":
    guard a.count >= 3, let id = find(a[2]), let v = current(id) else { exit(1) }
    print(String(format: "%.0f", v))

case "set":
    guard a.count >= 4, let id = find(a[2]), let v = Double(a[3]) else { exit(2) }
    apply(id, v)

case "daemon":
    guard a.count >= 6, let intervalMs = Double(a[2]), let panelNits = Double(a[3]),
          let panelGamma = Double(a[4]), panelNits > 0, panelGamma > 0 else { exit(2) }
    struct Target { let name: String; let lo: Double; let hi: Double; var applied: Double }
    var targets = a[5...].compactMap { spec -> Target? in
        let f = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, let lo = Double(f[1]), let hi = Double(f[2]) else { return nil }
        return Target(name: f[0], lo: lo, hi: hi, applied: -1)
    }
    guard !targets.isEmpty else { exit(2) }
    FileHandle.standardError.write("softdim daemon: \(targets.map{$0.name})\n".data(using: .utf8)!)

    // Gamma writes are sub-millisecond, so the ramp can be far finer than DDC allows.
    // The DDC agent and this daemon share one pause file. While paused the daemon
    // stops touching the gamma table entirely rather than holding its last value,
    // so another process - a calibration sweep, say - can own the display.
    let pauseFile = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/state/autobrightness.paused")
    while true {
        if FileManager.default.fileExists(atPath: pauseFile) {
            for i in targets.indices { targets[i].applied = -1 }
            Thread.sleep(forTimeInterval: intervalMs / 1000.0)
            continue
        }
        if let nits = builtinNits() {
            for i in targets.indices {
                guard let id = find(targets[i].name) else { targets[i].applied = -1; continue }
                // The gamma table scales the ENCODED signal, and the panel then
                // raises it to its own gamma. Scaling by 0.56 therefore emits about
                // 0.56^2.2 = 0.27 of full light, not 0.56 - which is why a naive
                // linear scale came out roughly twice too dark. Undo the panel
                // curve so the multiplier lands on the luminance we actually want.
                let ratio = max(0.0, min(1.0, nits / panelNits))
                let want = min(targets[i].hi, max(targets[i].lo, 100.0 * pow(ratio, 1.0 / panelGamma)))
                // Re-apply if the display was reconfigured and dropped our table.
                let live = current(id) ?? -1
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
