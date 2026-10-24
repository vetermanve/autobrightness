import Foundation

// The shape of `autobrightness --indicator`. Every number is optional because
// the agent reports honestly: with the lid shut and an empty model there is no
// ambient value at all, and a display that is unplugged has no reading.
public struct AmbientInfo: Decodable, Sendable {
    public let nits: Double?
    public let source: String
    public let age: Int
    public let slider: Double?
    public let elevation: Double?
}

public struct ModelInfo: Decodable, Sendable {
    public let bins: Int
    public let bins_total: Int
    public let bin_deg: Int
    public let on: Bool
}

public struct ManualInfo: Decodable, Sendable {
    public let nits: Double
}

public struct DisplayInfo: Decodable, Sendable {
    public let name: String
    public let mode: String
    public let connected: Bool
    public let target_lum: Int?
    public let target_blue: Int?
    public let lum: Int?
    public let blue: Int?
    /// how long ago the agent last refreshed this display's cached values
    public let age: Int?
}

public struct Snapshot: Decodable, Sendable {
    /// Contract version of the agent. The installed CLI is easily older than the
    /// app - both live in the same repo but are deployed by different commands -
    /// and then fields simply go missing, which looks like a bug in the bar.
    public let contract: Int?
    public let paused: Bool
    public let ambient: AmbientInfo
    public let model: ModelInfo
    public let manual: ManualInfo?
    public let displays: [DisplayInfo]
}

public let requiredContract = 1

/// What the ambient value is being taken from, and whether that is a measurement.
public enum AmbientSource: String, Sendable {
    case manual, sensor, als, solar, hold, none

    public init(_ raw: String) { self = AmbientSource(rawValue: raw) ?? .none }

    /// True when a sensor is reporting the room as it is right now.
    public var isMeasured: Bool { self == .als || self == .sensor }

    public var label: String {
        switch self {
        case .manual: return "set by hand"
        case .sensor: return "external meter"
        case .als:    return "built-in sensor"
        case .solar:  return "solar model"
        case .hold:   return "last reading, held"
        case .none:   return "no source"
        }
    }
}
