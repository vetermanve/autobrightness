// Prints the built-in display's brightness.
//
//   builtin-brightness          -> slider position, 0.0-1.0
//   builtin-brightness --nits   -> "<slider> <nits> <max_nits>"
//
// The slider is badly nonlinear in luminance: on a 14" M-series XDR, slider 0.10
// is about 1.5 nits while slider 1.00 is about 400. Matching an external monitor
// by slider percentage therefore leaves it roughly thirty times too bright in a
// dark room, which is why the nits reading exists.
import Foundation
import CoreGraphics
import IOKit

typealias GetBr = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

func slider() -> Double? {
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

// The built-in panel is the IOMobileFramebufferShim with no Transport property
// (external ones carry Upstream/Downstream) that still describes a display.
func builtinNits() -> (Double, Double)? {
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
        var cap = 0.0
        if let c = IORegistryEntryCreateCFProperty(svc, "IOMFBIndicatorNitsCap" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            cap = c.doubleValue / 65536.0
        }
        return (lv.doubleValue / 65536.0, cap)
    }
    return nil
}

guard let s = slider() else {
    FileHandle.standardError.write("no built-in display with readable brightness\n".data(using: .utf8)!)
    exit(1)
}
if CommandLine.arguments.contains("--nits") {
    guard let (nits, cap) = builtinNits() else {
        FileHandle.standardError.write("IOMFBBrightnessLevel not readable\n".data(using: .utf8)!)
        exit(1)
    }
    print(String(format: "%.4f %.1f %.1f", s, nits, cap))
} else {
    print(String(format: "%.4f", s))
}
