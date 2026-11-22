import SwiftUI

/// Column widths shared by header and rows.
private enum ColWidth {
    static let station: CGFloat = 150
    static let msgType: CGFloat = 72
    static let speed: CGFloat = 66
    static let heading: CGFloat = 52
    static let distance: CGFloat = 62
    static let longAccel: CGFloat = 70
    static let latAccel: CGFloat = 66
    static let steering: CGFloat = 58
    static let yaw: CGFloat = 66
    static let curvature: CGFloat = 68
    static let dimensions: CGFloat = 76
    static let lane: CGFloat = 44
    static let role: CGFloat = 96
    static let assist: CGFloat = 112
    static let lights: CGFloat = 112
    static let message: CGFloat = 136
    static let rate: CGFloat = 56
    static let frames: CGFloat = 50
}

/// Horizontally & vertically scrollable live telemetry matrix comparing all decoded station properties.
struct StationTableView: View {
    let stations: [Station]
    let distance: (Station) -> Double?
    let ownRole: (Station) -> StationOwnRole?
    let onSelect: (Station) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: headerRow) {
                    ForEach(Array(stations.enumerated()), id: \.element.id) { index, s in
                        Button {
                            onSelect(s)
                        } label: {
                            tableRow(s, striped: index.isMultiple(of: 2) == false)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            headerCell("Station", width: ColWidth.station, align: .leading)
            headerCell("Typ", width: ColWidth.msgType, align: .leading)
            headerCell("Tempo", width: ColWidth.speed, align: .trailing)
            headerCell("Kurs", width: ColWidth.heading, align: .trailing)
            headerCell("Entf.", width: ColWidth.distance, align: .trailing)
            headerCell("Längs", width: ColWidth.longAccel, align: .trailing)
            headerCell("Quer", width: ColWidth.latAccel, align: .trailing)
            headerCell("Lenk.", width: ColWidth.steering, align: .trailing)
            headerCell("Gier", width: ColWidth.yaw, align: .trailing)
            headerCell("Kurve", width: ColWidth.curvature, align: .trailing)
            headerCell("Maße", width: ColWidth.dimensions, align: .trailing)
            headerCell("Spur", width: ColWidth.lane, align: .trailing)
            headerCell("Rolle", width: ColWidth.role, align: .leading)
            headerCell("Assistenten", width: ColWidth.assist, align: .leading)
            headerCell("Lichter", width: ColWidth.lights, align: .leading)
            headerCell("Meldung", width: ColWidth.message, align: .leading)
            headerCell("Rate", width: ColWidth.rate, align: .trailing)
            headerCell("Frames", width: ColWidth.frames, align: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tableRow(_ s: Station, striped: Bool) -> some View {
        let active = s.isActive
        let role = ownRole(s)
        let cam = s.cam

        return HStack(spacing: 8) {
            // Station column: status dot + icon + class + own badge + short ID
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 7, height: 7)
                Image(systemName: s.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(s.tint(isOwn: role == .current))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(s.stationClassLabel)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let role {
                            OwnRoleBadge(role: role, pastText: "alt", style: .table)
                        }
                    }
                    Text(shortHex(s.idHex))
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: ColWidth.station, alignment: .leading)

            cell(s.sortedMsgTypes.map(\.rawValue).joined(separator: "/"), width: ColWidth.msgType, align: .leading, color: s.msgType.color)
            cell(s.speedMps.map(\.speedKmhText) ?? "–", width: ColWidth.speed, align: .trailing, mono: true)
            cell(s.headingDeg.map { String(format: "%.0f°", $0) } ?? "–", width: ColWidth.heading, align: .trailing, mono: true)
            cell(distance(s).map { $0.distanceText() } ?? "–", width: ColWidth.distance, align: .trailing, mono: true)
            cell(
                cam?.longAccel.map { String(format: "%+.1f", $0) } ?? "–",
                width: ColWidth.longAccel,
                align: .trailing,
                mono: true,
                color: cam?.longAccel?.accelerationColor ?? Color.primary
            )
            cell(cam?.latAccel.map { String(format: "%+.1f", $0) } ?? "–", width: ColWidth.latAccel, align: .trailing, mono: true)
            cell(cam?.steeringWheelDeg.map { String(format: "%+.0f°", $0) } ?? "–", width: ColWidth.steering, align: .trailing, mono: true)
            cell(cam?.yawRateDegPerSec.map { String(format: "%+.1f", $0) } ?? "–", width: ColWidth.yaw, align: .trailing, mono: true)
            cell(formatCurvature(cam?.curvature, radius: cam?.curveRadiusM), width: ColWidth.curvature, align: .trailing, mono: true)
            cell(formatDimensions(cam?.lengthM, cam?.widthM), width: ColWidth.dimensions, align: .trailing, mono: true)
            cell(cam?.lanePosition.map(formatLane) ?? "–", width: ColWidth.lane, align: .trailing, mono: true)
            cell(cam?.vehicleRole?.label ?? "–", width: ColWidth.role, align: .leading)
            cell(formatControl(cam?.control), width: ColWidth.assist, align: .leading, color: s.braking ? .red : .primary)
            cell(formatLights(cam?.lights), width: ColWidth.lights, align: .leading)
            cell(formatMessage(s), width: ColWidth.message, align: .leading, color: messageColor(s))
            cell(s.updateRateHz.map { String(format: "%.1f Hz", $0) } ?? "–", width: ColWidth.rate, align: .trailing, mono: true)
            cell("\(s.count)", width: ColWidth.frames, align: .trailing, mono: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(striped ? Color.secondary.opacity(0.05) : Color.clear)
        .opacity(active ? 1 : 0.6)
        .contentShape(Rectangle())
    }

    private func headerCell(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: align)
            .lineLimit(1)
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment, mono: Bool = false, color: Color = .primary) -> some View {
        Text(text)
            .font(mono ? .caption.monospacedDigit() : .caption)
            .foregroundStyle(text == "–" ? Color.secondary.opacity(0.45) : color)
            .frame(width: width, alignment: align)
            .lineLimit(1)
    }

    private func shortHex(_ hex: String) -> String {
        hex.count > 8 ? "…" + hex.suffix(8) : hex
    }

    private func formatCurvature(_ raw: Int?, radius: Double?) -> String {
        guard let raw else { return "–" }
        if raw == 0 { return "gerade" }
        guard let r = radius else { return "–" }
        let absR = abs(r)
        if absR >= 5000 { return "gerade" }
        return String(format: "%.0fm %@", absR, r > 0 ? "L" : "R")
    }

    private func formatDimensions(_ l: Double?, _ w: Double?) -> String {
        if let l, let w { return String(format: "%.1f×%.1fm", l, w) }
        if let l { return String(format: "%.1fm L", l) }
        if let w { return String(format: "%.1fm B", w) }
        return "–"
    }

    private func formatLane(_ lane: Int) -> String {
        switch lane {
        case -1: "Aus"
        case 0: "S-I"
        case 14: "S-A"
        default: "\(lane)"
        }
    }

    private func formatControl(_ ctl: CamParser.Control?) -> String {
        guard let ctl else { return "–" }
        var p: [String] = []
        if ctl.contains(.emergencyBrake) { p.append("NOTBR") }
        else if ctl.contains(.brakePedal) { p.append("Bremse") }
        if ctl.contains(.collisionWarning) { p.append("Koll") }
        if ctl.contains(.acc) { p.append("ACC") }
        if ctl.contains(.cruiseControl) { p.append("CC") }
        if ctl.contains(.speedLimiter) { p.append("LIM") }
        if ctl.contains(.gasPedal) { p.append("Gas") }
        return p.isEmpty ? "–" : p.joined(separator: " ")
    }

    private func formatLights(_ l: CamParser.Lights?) -> String {
        guard let l else { return "–" }
        var p: [String] = []
        if l.contains(.leftTurn) && l.contains(.rightTurn) { p.append("⚠") }
        else if l.contains(.leftTurn) { p.append("◀") }
        else if l.contains(.rightTurn) { p.append("▶") }
        if l.contains(.highBeam) { p.append("Fern") }
        else if l.contains(.lowBeam) { p.append("Abbl") }
        if l.contains(.fog) { p.append("Nebel") }
        if l.contains(.reverse) { p.append("R") }
        if l.contains(.daytime) && !l.contains(.lowBeam) && !l.contains(.highBeam) { p.append("TFL") }
        if l.contains(.parking) && p.isEmpty { p.append("Stand") }
        return p.isEmpty ? "–" : p.joined(separator: " ")
    }

    private func formatMessage(_ s: Station) -> String {
        if let c = s.denmCause {
            return c.displayText
        }
        if let p = s.spatPhase, p != .unknown { return "Ampel: \(p.label)" }
        if s.hasSiren { return "Martinshorn" }
        if s.hasLightBar { return "Blaulicht" }
        return "–"
    }

    private func messageColor(_ s: Station) -> Color {
        if s.denmCause != nil { return .orange }
        if let p = s.spatPhase, p != .unknown { return p.textColor }
        if s.hasSiren || s.hasLightBar { return .blue }
        return .primary
    }
}
