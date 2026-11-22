import SwiftUI

/// Whether a station is the current own vehicle or one of its superseded pseudonym IDs.
enum StationOwnRole { case current, past }

extension AppModel {
    func ownRole(for id: UInt64) -> StationOwnRole? {
        if ego.egoId == id { return .current }
        if ego.isSupersededOwnVehicle(id) { return .past }
        return nil
    }
}

/// Font and padding of a capsule badge; one preset per place it appears.
struct BadgeStyle {
    let font: Font
    let horizontal: CGFloat
    let vertical: CGFloat

    static let marker = BadgeStyle(font: Font.system(size: 9, weight: .heavy), horizontal: 5, vertical: 1)
    static let row = BadgeStyle(font: Font.caption2.weight(.bold), horizontal: 5, vertical: 1)
    static let detail = BadgeStyle(font: Font.caption2.weight(.bold), horizontal: 6, vertical: 2)
    static let table = BadgeStyle(font: Font.system(size: 8, weight: .heavy), horizontal: 4, vertical: 1)
}

/// White text on a filled capsule.
struct CapsuleBadge: View {
    let text: String
    let fill: Color
    let style: BadgeStyle

    var body: some View {
        Text(text)
            .font(style.font)
            .foregroundStyle(.white)
            .padding(.horizontal, style.horizontal)
            .padding(.vertical, style.vertical)
            .background(fill, in: Capsule())
    }
}

/// "ICH" (teal) for the own vehicle, "ICH (alt)" (grey) for a superseded own pseudonym.
struct OwnRoleBadge: View {
    let role: StationOwnRole
    var pastText = "ICH (alt)"
    let style: BadgeStyle

    var body: some View {
        CapsuleBadge(text: role == .current ? "ICH" : pastText,
                     fill: role == .current ? Color.teal : Color.secondary,
                     style: style)
    }
}

/// "SIRENE" / "BLAULICHT" capsule; callers decide when to show it (siren or light bar present).
struct EmergencyBadge: View {
    let station: Station
    let style: BadgeStyle

    var body: some View {
        CapsuleBadge(text: station.hasSiren ? "SIRENE" : "BLAULICHT", fill: Color.blue, style: style)
    }
}

/// One tinted capsule per message type the station sends, highest display priority first.
struct MsgTypeBadges: View {
    let station: Station
    let font: Font
    let fillOpacity: Double

    var body: some View {
        ForEach(station.sortedMsgTypes, id: \.self) { t in
            Text(t.rawValue)
                .font(font)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(t.color.opacity(fillOpacity), in: Capsule())
                .foregroundStyle(t.color)
        }
    }
}

/// Filled circle with the station's SF Symbol.
struct StationIcon: View {
    let symbol: String
    let fill: Color
    var diameter: CGFloat = 30
    var glyphSize: CGFloat = 13

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: diameter, height: diameter)
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
