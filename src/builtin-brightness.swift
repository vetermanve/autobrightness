// Prints the built-in display's brightness (0.0-1.0) using the private
// DisplayServices API. External displays return a non-zero status code -
// they are driven over DDC instead.
import Foundation
import CoreGraphics

typealias GetBr = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
      let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
    FileHandle.standardError.write("DisplayServices unavailable\n".data(using: .utf8)!)
    exit(1)
}
let getBrightness = unsafeBitCast(sym, to: GetBr.self)

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)

for id in ids where CGDisplayIsBuiltin(id) != 0 {
    var value: Float = -1
    if getBrightness(id, &value) == 0 {
        print(String(format: "%.4f", value))
        exit(0)
    }
}
FileHandle.standardError.write("no built-in display with readable brightness\n".data(using: .utf8)!)
exit(1)
