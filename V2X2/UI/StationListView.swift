import CoreLocation
import SwiftUI

/// Station overview with a compact list view and a full live telemetry comparison table.
struct StationListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onFocus: ((CLLocationCoordinate2D) -> Void)?

    @State private var mode = 0
    @State private var activeOnly = false
    @State private var selectedStation: StationSelection?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let all = model.stations.values.sorted { lhs, rhs in
                    if lhs.isActive != rhs.isActive { return lhs.isActive }
                    return lhs.lastSeen > rhs.lastSeen
                }
                let activeCount = all.filter(\.isActive).count
                let stations = activeOnly ? all.filter(\.isActive) : all

                VStack(spacing: 0) {
                    if !all.isEmpty {
                        HStack(spacing: 10) {
                            Picker("Ansicht", selection: $mode) {
                                Label("Liste", systemImage: "list.bullet").tag(0)
                                Label("Tabelle", systemImage: "tablecells").tag(1)
                            }
                            .pickerStyle(.segmented)

                            Button {
                                activeOnly.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(activeOnly ? Color.white : Color.green)
                                        .frame(width: 7, height: 7)
                                    Text("Aktiv (\(activeCount))")
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(activeOnly ? Color.accentColor : Color.secondary.opacity(0.14), in: Capsule())
                                .foregroundStyle(activeOnly ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        Divider()
                    }

                    Group {
                        if stations.isEmpty {
                            if all.isEmpty {
                                ContentUnavailableView(
                                    "Noch nichts empfangen",
                                    systemImage: "dot.radiowaves.left.and.right",
                                    description: Text("Sobald der Empfänger ITS-G5-Meldungen sieht, erscheinen sie hier.")
                                )
                            } else {
                                ContentUnavailableView(
                                    "Keine aktiven Stationen",
                                    systemImage: "antenna.radiowaves.left.and.right.slash",
                                    description: Text("Alle \(all.count) empfangenen Stationen sind derzeit inaktiv.")
                                )
                            }
                        } else if mode == 0 {
                            List(stations) { s in
                                Button {
                                    selectedStation = StationSelection(id: s.id)
                                } label: {
                                    StationRow(
                                        station: s,
                                        distance: s.coordinate.flatMap { model.distance(to: $0) },
                                        ownRole: ownRole(for: s.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .listStyle(.plain)
                        } else {
                            StationTableView(
                                stations: stations,
                                distance: { s in s.coordinate.flatMap { model.distance(to: $0) } },
                                ownRole: { s in ownRole(for: s.id) },
                                onSelect: { s in selectedStation = StationSelection(id: s.id) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Stationen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Leeren", role: .destructive) { model.clear() }
                        .disabled(model.stations.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(item: $selectedStation) { sel in
                StationDetailView(
                    stationId: sel.id,
                    onFocus: onFocus.map { focus in
                        { coord in
                            focus(coord)
                            dismiss()
                        }
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func ownRole(for id: UInt64) -> StationOwnRole? {
        if model.ego.egoId == id { return .current }
        if model.ego.isSupersededOwnVehicle(id) { return .past }
        return nil
    }
}

private enum StationOwnRole { case current, past }

private struct StationRow: View {
    let station: Station
    let distance: Double?
    let ownRole: StationOwnRole?

    var body: some View {
        let active = station.isActive
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(active ? 1 : 0.35))
                    .frame(width: 30, height: 30)
                Image(systemName: station.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(station.stationClassLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let ownRole {
                        Text(ownRole == .current ? "ICH" : "ICH (alt)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(ownRole == .current ? Color.teal : Color.secondary, in: Capsule())
                    }
                    if station.hasSiren || station.hasLightBar {
                        Text(station.hasSiren ? "SIRENE" : "BLAULICHT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue, in: Capsule())
                    }
                    if let sec = station.secured { Text(sec ? "🔒" : "🔓").font(.caption2) }
                }
                HStack(spacing: 4) {
                    ForEach(station.sortedMsgTypes, id: \.self) { t in
                        Text(t.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(t.color.opacity(0.16), in: Capsule())
                            .foregroundStyle(t.color)
                    }
                    Text(station.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !station.statusText.isEmpty {
                    Text(station.statusText)
                        .font(.caption)
                        .foregroundStyle(station.braking ? Color.red : (station.hasSiren || station.hasLightBar ? Color.blue : Color.primary))
                        .lineLimit(1)
                }
                Text(metaLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let d = distance {
                    Text(d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(active ? 1 : 0.65)
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        if ownRole == .current { return .teal }
        if station.isEmergency { return .indigo }
        return station.msgType.color
    }

    private var metaLine: String {
        var parts = [station.idHex, "\(station.count)×"]
        if let hz = station.updateRateHz {
            parts.append(String(format: "%.1f Hz", hz))
        }
        parts.append(station.lastSeen.formatted(date: .omitted, time: .standard))
        return parts.joined(separator: " · ")
    }
}

/// Horizontally & vertically scrollable live telemetry matrix comparing all decoded station properties.
private struct StationTableView: View {
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
            headerCell("Station", width: 150, align: .leading)
            headerCell("Typ", width: 72, align: .leading)
            headerCell("Tempo", width: 66, align: .trailing)
            headerCell("Kurs", width: 52, align: .trailing)
            headerCell("Entf.", width: 62, align: .trailing)
            headerCell("Längs", width: 70, align: .trailing)
            headerCell("Quer", width: 66, align: .trailing)
            headerCell("Lenk.", width: 58, align: .trailing)
            headerCell("Gier", width: 66, align: .trailing)
            headerCell("Kurve", width: 68, align: .trailing)
            headerCell("Maße", width: 76, align: .trailing)
            headerCell("Spur", width: 44, align: .trailing)
            headerCell("Rolle", width: 96, align: .leading)
            headerCell("Assistenten", width: 112, align: .leading)
            headerCell("Lichter", width: 112, align: .leading)
            headerCell("Meldung", width: 136, align: .leading)
            headerCell("Rate", width: 56, align: .trailing)
            headerCell("Frames", width: 50, align: .trailing)
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
                    .foregroundStyle(role == .current ? Color.teal : (s.isEmergency ? Color.indigo : s.msgType.color))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(s.stationClassLabel)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let role {
                            Text(role == .current ? "ICH" : "alt")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(role == .current ? Color.teal : Color.secondary, in: Capsule())
                        }
                    }
                    Text(shortHex(s.idHex))
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 150, alignment: .leading)

            cell(s.sortedMsgTypes.map(\.rawValue).joined(separator: "/"), width: 72, align: .leading, color: s.msgType.color)
            cell(s.speedMps.map { String(format: "%.0f km/h", $0 * 3.6) } ?? "–", width: 66, align: .trailing, mono: true)
            cell(s.headingDeg.map { String(format: "%.0f°", $0) } ?? "–", width: 52, align: .trailing, mono: true)
            cell(distance(s).map(formatDistance) ?? "–", width: 62, align: .trailing, mono: true)
            cell(
                cam?.longAccel.map { String(format: "%+.1f", $0) } ?? "–",
                width: 70,
                align: .trailing,
                mono: true,
                color: accelColor(cam?.longAccel)
            )
            cell(cam?.latAccel.map { String(format: "%+.1f", $0) } ?? "–", width: 66, align: .trailing, mono: true)
            cell(cam?.steeringWheelDeg.map { String(format: "%+.0f°", $0) } ?? "–", width: 58, align: .trailing, mono: true)
            cell(cam?.yawRateDegPerSec.map { String(format: "%+.1f", $0) } ?? "–", width: 66, align: .trailing, mono: true)
            cell(formatCurvature(cam?.curvature, radius: cam?.curveRadiusM), width: 68, align: .trailing, mono: true)
            cell(formatDimensions(cam?.lengthM, cam?.widthM), width: 76, align: .trailing, mono: true)
            cell(cam?.lanePosition.map(formatLane) ?? "–", width: 44, align: .trailing, mono: true)
            cell(cam?.vehicleRole?.label ?? "–", width: 96, align: .leading)
            cell(formatControl(cam?.control), width: 112, align: .leading, color: s.braking ? .red : .primary)
            cell(formatLights(cam?.lights), width: 112, align: .leading)
            cell(formatMessage(s), width: 136, align: .leading, color: messageColor(s))
            cell(s.updateRateHz.map { String(format: "%.1f Hz", $0) } ?? "–", width: 56, align: .trailing, mono: true)
            cell("\(s.count)", width: 50, align: .trailing, mono: true)
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

    private func formatDistance(_ d: Double) -> String {
        d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000)
    }

    private func accelColor(_ a: Double?) -> Color {
        guard let a else { return .primary }
        if a <= -1.0 { return .red }
        if a >= 1.0 { return .green }
        return .primary
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
            return "\(c.label) \(c.sublabel)".trimmingCharacters(in: .whitespaces)
        }
        if let p = s.spatPhase, p != .unknown {
            switch p {
            case .red: return "Ampel: Rot"
            case .yellow: return "Ampel: Gelb"
            case .green: return "Ampel: Grün"
            case .unknown: break
            }
        }
        if s.hasSiren { return "Martinshorn" }
        if s.hasLightBar { return "Blaulicht" }
        return "–"
    }

    private func messageColor(_ s: Station) -> Color {
        if s.denmCause != nil { return .orange }
        if let p = s.spatPhase {
            switch p {
            case .red: return .red
            case .yellow: return .orange
            case .green: return .green
            case .unknown: break
            }
        }
        if s.hasSiren || s.hasLightBar { return .blue }
        return .primary
    }
}
