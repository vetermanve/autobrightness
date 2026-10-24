import Foundation

/// The nits scale the manual slider speaks in.
///
/// Luminance has to be logarithmic here. The built-in panel runs from about one
/// nit in a dark room to several hundred in daylight, and on a linear slider the
/// whole evening range - one to twenty nits, where a mismatch is most visible -
/// would be squeezed into the first few percent of travel.
public struct AmbientScale: Sendable {
    public let lo: Double
    public let hi: Double

    public init(lo: Double = 1.0, hi: Double = 400.0) {
        self.lo = lo
        self.hi = hi
    }

    /// nits -> 0...1
    public func position(_ nits: Double) -> Double {
        guard hi > lo, lo > 0 else { return 0 }
        let t = (log(max(lo, min(hi, nits))) - log(lo)) / (log(hi) - log(lo))
        return max(0, min(1, t))
    }

    /// 0...1 -> nits
    public func nits(_ position: Double) -> Double {
        guard hi > lo, lo > 0 else { return lo }
        let p = max(0, min(1, position))
        return exp(log(lo) + p * (log(hi) - log(lo)))
    }

    /// One decimal below ten nits, none above: a tenth of a nit matters in the
    /// dark and is noise at noon.
    public func format(_ nits: Double) -> String {
        nits < 10 ? String(format: "%.1f nits", nits) : String(format: "%.0f nits", nits)
    }
}
