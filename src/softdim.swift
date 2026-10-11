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
//   softdim daemon <interval_ms> <b_lo> <b_hi> <name:lum_min:lum_max> ...
import CoreGraphics
import AppKit
import Foundation

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

typealias GetBr = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
func builtinBrightness() -> Double? {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    let fn = unsafeBitCast(sym, to: GetBr.self)
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    for id in ids where CGDisplayIsBuiltin(id) != 0 {
        var v: Float = -1
        if fn(id, &v) == 0 { return Double(v) }
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
    guard a.count >= 6, let intervalMs = Double(a[2]),
          let bLo = Double(a[3]), let bHi = Double(a[4]) else { exit(2) }
    struct Target { let name: String; let lo: Double; let hi: Double; var applied: Double }
    var targets = a[5...].compactMap { spec -> Target? in
        let f = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, let lo = Double(f[1]), let hi = Double(f[2]) else { return nil }
        return Target(name: f[0], lo: lo, hi: hi, applied: -1)
    }
    guard !targets.isEmpty else { exit(2) }
    FileHandle.standardError.write("softdim daemon: \(targets.map{$0.name})\n".data(using: .utf8)!)

    // Gamma writes are sub-millisecond, so the ramp can be far finer than DDC allows.
    while true {
        if let b = builtinBrightness() {
            for i in targets.indices {
                guard let id = find(targets[i].name) else { targets[i].applied = -1; continue }
                let want = interp(b, bLo, bHi, targets[i].lo, targets[i].hi)
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

default: exit(2)
}
