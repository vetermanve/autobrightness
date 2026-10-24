import Foundation

/// Coordinates from the system's time zone database.
///
/// The solar model needs to know where it is, and asking CoreLocation means a
/// permission prompt that an ad-hoc signed app does not reliably get. macOS
/// already ships the answer: `/usr/share/zoneinfo/zone.tab` carries an ISO 6709
/// position for every zone, so `Europe/Moscow` is +554521+0373704 without asking
/// anyone anything.
///
/// It is the zone's reference city, not the machine - good to a city, which is
/// what the model needs: a degree of latitude is 110 km, and the sun's elevation
/// is what gets bucketed in five degree steps. The number stays editable for
/// anyone who is not in the capital of their time zone.
public enum TimeZoneCoords {

    public struct Place: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let zone: String
        /// the zone.tab comment, e.g. "MSK+00 - Moscow area"
        public let comment: String
    }

    public static let tabPath = "/usr/share/zoneinfo/zone.tab"

    public static func current(zone: String = TimeZone.current.identifier,
                               tabPath: String = tabPath) -> Place? {
        guard let text = try? String(contentsOfFile: tabPath, encoding: .utf8) else { return nil }
        return lookup(zone: zone, in: text)
    }

    public static func lookup(zone: String, in tab: String) -> Place? {
        for line in tab.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, f[2] == zone, let c = parseISO6709(f[1]) else { continue }
            return Place(latitude: c.lat, longitude: c.lon, zone: zone,
                         comment: f.count > 3 ? f[3] : "")
        }
        return nil
    }

    /// "+554521+0373704" or the shorter "+5545+03737" that older rows use.
    public static func parseISO6709(_ raw: String) -> (lat: Double, lon: Double)? {
        let s = Array(raw)
        guard s.count >= 11, s[0] == "+" || s[0] == "-" else { return nil }
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        guard let lat = sexagesimal(String(s[0..<split]), degreeDigits: 2),
              let lon = sexagesimal(String(s[split...]), degreeDigits: 3),
              lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
        return (lat, lon)
    }

    /// sign, then DD or DDD degrees, then MM minutes, then optional SS seconds
    static func sexagesimal(_ field: String, degreeDigits: Int) -> Double? {
        var c = Array(field)
        guard !c.isEmpty else { return nil }
        let sign: Double = c.removeFirst() == "-" ? -1 : 1
        guard c.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard c.count == degreeDigits + 2 || c.count == degreeDigits + 4 else { return nil }
        func num(_ r: Range<Int>) -> Double? { Double(String(c[r])) }
        guard let d = num(0..<degreeDigits), let m = num(degreeDigits..<(degreeDigits + 2)),
              m < 60 else { return nil }
        var sec = 0.0
        if c.count == degreeDigits + 4 {
            guard let s = num((degreeDigits + 2)..<c.count), s < 60 else { return nil }
            sec = s
        }
        return sign * (d + m / 60 + sec / 3600)
    }
}
