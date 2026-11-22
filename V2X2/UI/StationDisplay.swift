import SwiftUI

/// Shared display logic for stations, so map, list, table, detail and CarPlay agree on colors and text.

extension Station {
    /// Tint for a station's marker / icon. Precedence: own vehicle, emergency, traffic-light phase, braking, message type.
    /// - Parameters:
    ///   - isOwn: the station is the current own vehicle (teal).
    ///   - phase: color traffic-light stations by their SPAT phase (map marker, CarPlay pin).
    ///   - brakingRed: color braking vehicles red (CarPlay pin).
    func tint(isOwn: Bool = false, phase: Bool = false, brakingRed: Bool = false) -> Color {
        if isOwn { return .teal }
        if isEmergency { return .indigo }
        if phase {
            switch spatPhase {
            case .red: return .red
            case .yellow: return .yellow
            case .green: return .green
            default: break
            }
        }
        if brakingRed, braking { return .red }
        return msgType.color
    }
}

extension SpatTemParser.Phase {
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .unknown: .gray
        }
    }

    /// Like `color`, but yellow is orange so it stays readable as text.
    var textColor: Color { self == .yellow ? Color.orange : color }

    var label: String {
        switch self {
        case .red: "Rot"
        case .yellow: "Gelb"
        case .green: "Grün"
        case .unknown: "Unbekannt"
        }
    }
}

extension DenmParser.Cause {
    /// e.g. "Stau Stauende" (sublabel may be empty).
    var displayText: String { "\(label) \(sublabel)".trimmingCharacters(in: .whitespaces) }
}

extension Double {
    /// Meters as "123 m", or kilometers with `kmDecimals` decimals from 1000 m.
    func distanceText(kmDecimals: Int = 1) -> String {
        self < 1000 ? String(format: "%.0f m", self) : String(format: "%.\(kmDecimals)f km", self / 1000)
    }

    /// Treats `self` as m/s and formats it as "50 km/h".
    var speedKmhText: String { String(format: "%.0f km/h", self * 3.6) }

    /// Longitudinal acceleration (m/s²): red when braking (≤ −1), green when accelerating (≥ +1).
    var accelerationColor: Color {
        if self <= -1.0 { return .red }
        if self >= 1.0 { return .green }
        return .primary
    }
}
