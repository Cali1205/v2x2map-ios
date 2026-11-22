import CoreLocation
import SwiftUI

/// Identifiable station ID wrapper for presenting `StationDetailView` via `.sheet(item:)`.
struct StationSelection: Identifiable, Hashable {
    let id: UInt64
}

/// Live structured telemetry inspector for a single V2X station (vehicle, traffic light or hazard).
struct StationDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let stationId: UInt64
    var onFocus: ((CLLocationCoordinate2D) -> Void)?

    var body: some View {
        NavigationStack {
            Group {
                if let s = model.stations[stationId] {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        content(s)
                    }
                } else {
                    ContentUnavailableView("Station nicht mehr aktiv",
                                           systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Diese Station ist abgelaufen oder wurde geleert."))
                }
            }
            .navigationTitle("Telemetrie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onFocus, let c = model.stations[stationId]?.coordinate {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onFocus(c)
                            dismiss()
                        } label: {
                            Label("Karte", systemImage: "scope")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ s: Station) -> some View {
        let role = model.ownRole(for: s.id)
        let age = max(0, Int(Clock.now.timeIntervalSince(s.lastSeen).rounded()))

        List {
            headerSection(s, role: role, age: age)
            messageSection(s)
            motionSection(s)

            if let cam = s.cam {
                dynamicsSection(cam)
                vehicleSection(s, cam: cam)
                controlSection(cam)
                lightsSection(cam)
            }

            protocolSection(s, age: age)
        }
        .listStyle(.insetGrouped)
    }

    private func headerSection(_ s: Station, role: StationOwnRole?, age: Int) -> some View {
        let active = s.isActive
        return Section {
            HStack(spacing: 12) {
                StationIcon(symbol: s.symbol, fill: s.tint(isOwn: role == .current), diameter: 42, glyphSize: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(s.stationClassLabel).font(.headline)
                        if let role {
                            OwnRoleBadge(role: role, style: .detail)
                        }
                        if s.hasSiren || s.hasLightBar {
                            EmergencyBadge(station: s, style: .detail)
                        }
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(active ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(active ? "Aktiv" : "Inaktiv (vor \(age) s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MsgTypeBadges(station: s, font: .caption2.weight(.semibold), fillOpacity: 0.18)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func messageSection(_ s: Station) -> some View {
        if s.denmCause != nil || (s.spatPhase != nil && s.spatPhase != .unknown) {
            Section("Meldung") {
                if let c = s.denmCause {
                    LabeledContent("Gefahr") {
                        Text(c.displayText)
                            .foregroundStyle(.orange)
                            .fontWeight(.semibold)
                    }
                    LabeledContent("Code", value: "\(c.causeCode) / \(c.subCauseCode)")
                }
                if let p = s.spatPhase, p != .unknown {
                    LabeledContent("Ampelphase") {
                        HStack(spacing: 6) {
                            Circle().fill(p.color).frame(width: 10, height: 10)
                            Text(p.label).fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private func motionSection(_ s: Station) -> some View {
        Section("Bewegung & Position") {
            if let v = s.speedMps {
                LabeledContent("Geschwindigkeit",
                               value: String(format: "%.1f km/h (%.1f m/s)", v * 3.6, v))
            }
            if let h = s.headingDeg {
                LabeledContent("Kurs", value: String(format: "%.1f° (%@)", h, compass(h)))
            }
            if let dir = s.cam?.driveDirection {
                LabeledContent("Fahrtrichtung", value: dir.label)
            }
            if let c = s.coordinate, let d = model.distance(to: c) {
                LabeledContent("Entfernung", value: d.distanceText(kmDecimals: 2))
            }
            if let lane = s.cam?.lanePosition {
                LabeledContent("Spurposition", value: laneLabel(lane))
            }
            if let c = s.coordinate {
                LabeledContent("Koordinaten") {
                    Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                        .font(.caption.monospacedDigit())
                        .textSelection(.enabled)
                }
            }
            if let alt = s.altitudeM {
                LabeledContent("Höhe", value: String(format: "%.0f m", alt))
            }
        }
    }

    @ViewBuilder
    private func dynamicsSection(_ cam: CamParser.State) -> some View {
        if cam.longAccel != nil || cam.latAccel != nil || cam.vertAccel != nil
            || cam.steeringWheelDeg != nil || cam.yawRateDegPerSec != nil || cam.curvature != nil {
            Section("Fahrdynamik") {
                if let a = cam.longAccel {
                    LabeledContent("Längsbeschleunigung") {
                        Text(String(format: "%+.2f m/s²", a))
                            .monospacedDigit()
                            .foregroundStyle(a.accelerationColor)
                    }
                }
                if let la = cam.latAccel {
                    LabeledContent("Querbeschleunigung", value: String(format: "%+.2f m/s²", la))
                }
                if let va = cam.vertAccel {
                    LabeledContent("Vertikalbeschleunigung", value: String(format: "%+.2f m/s²", va))
                }
                if let sw = cam.steeringWheelDeg {
                    LabeledContent("Lenkwinkel", value: String(format: "%+.1f°", sw))
                }
                if let yaw = cam.yawRateDegPerSec {
                    LabeledContent("Gierrate", value: String(format: "%+.2f °/s", yaw))
                }
                if let curv = cam.curvature {
                    LabeledContent("Kurvenradius", value: curvatureLabel(curv, radius: cam.curveRadiusM))
                }
            }
        }
    }

    private func vehicleSection(_ s: Station, cam: CamParser.State) -> some View {
        Section("Fahrzeug") {
            LabeledContent("Klasse", value: s.stationClassLabel)
            if let role = cam.vehicleRole {
                LabeledContent("Rolle", value: role.label)
            }
            if let l = cam.lengthM, let w = cam.widthM {
                LabeledContent("Abmessungen", value: String(format: "%.1f m × %.1f m", l, w))
            } else if let l = cam.lengthM {
                LabeledContent("Länge", value: String(format: "%.1f m", l))
            } else if let w = cam.widthM {
                LabeledContent("Breite", value: String(format: "%.1f m", w))
            }
            if let pc = cam.performanceClass {
                LabeledContent("Leistungsklasse", value: "Klasse \(pc)")
            }
            if let lb = cam.lightBar {
                LabeledContent("Blaulicht / Warnleuchte", value: lb ? "Aktiv" : "Aus")
            }
            if let sr = cam.siren {
                LabeledContent("Martinshorn", value: sr ? "Aktiv" : "Aus")
            }
        }
    }

    @ViewBuilder
    private func controlSection(_ cam: CamParser.State) -> some View {
        if let ctl = cam.control {
            Section("Assistenz & Pedale") {
                FlagGrid(items: [
                    ("Bremspedal", ctl.contains(.brakePedal), .red),
                    ("Notbremsung", ctl.contains(.emergencyBrake), .red),
                    ("Kollisionswarnung", ctl.contains(.collisionWarning), .orange),
                    ("Gaspedal", ctl.contains(.gasPedal), .green),
                    ("ACC", ctl.contains(.acc), .blue),
                    ("Tempomat", ctl.contains(.cruiseControl), .blue),
                    ("Limiter", ctl.contains(.speedLimiter), .purple),
                ])
            }
        }
    }

    @ViewBuilder
    private func lightsSection(_ cam: CamParser.State) -> some View {
        if let l = cam.lights {
            Section("Beleuchtung") {
                FlagGrid(items: [
                    ("Blinker links", l.contains(.leftTurn), .orange),
                    ("Blinker rechts", l.contains(.rightTurn), .orange),
                    ("Abblendlicht", l.contains(.lowBeam), .blue),
                    ("Fernlicht", l.contains(.highBeam), .indigo),
                    ("Tagfahrlicht", l.contains(.daytime), .teal),
                    ("Nebellicht", l.contains(.fog), .yellow),
                    ("Rückfahrlicht", l.contains(.reverse), .red),
                    ("Standlicht", l.contains(.parking), .cyan),
                ])
            }
        }
    }

    private func protocolSection(_ s: Station, age: Int) -> some View {
        Section("Funk & Protokoll") {
            LabeledContent("Station-ID") {
                Text(s.idHex)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let sec = s.secured {
                LabeledContent("Signatur", value: sec ? "🔒 IEEE 1609.2 signiert" : "🔓 Unsigniert")
            }
            if let hz = s.updateRateHz {
                LabeledContent("Empfangsrate", value: String(format: "%.1f Hz", hz))
            }
            LabeledContent("Frames empfangen", value: "\(s.count)")
            if let ph = s.cam?.pathHistoryCount {
                LabeledContent("PathHistory-Punkte", value: "\(ph)")
            }
            LabeledContent("Zuletzt gesehen",
                           value: "\(s.lastSeen.formatted(date: .omitted, time: .standard)) (vor \(age) s)")
            if !s.recent.isEmpty {
                DisclosureGroup("Letzte \(s.recent.count) Rohframes") {
                    ForEach(s.recent) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(f.received.formatted(date: .omitted, time: .standard)) · \(f.decoded.msgType.rawValue) · \(f.payload.count) B")
                                .font(.caption)
                            Text(f.hexPreview())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func compass(_ deg: Double) -> String {
        let dirs = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let idx = Int(((deg + 22.5).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45) % 8
        return dirs[idx]
    }

    private func laneLabel(_ lane: Int) -> String {
        switch lane {
        case -1: "Außerhalb Fahrbahn"
        case 0: "Seitenstreifen innen"
        case 1: "Spur 1 (links)"
        case 14: "Seitenstreifen außen"
        default: "Spur \(lane)"
        }
    }

    private func curvatureLabel(_ raw: Int, radius: Double?) -> String {
        if raw == 0 { return "geradeaus" }
        guard let r = radius else { return "–" }
        let side = r > 0 ? "links" : "rechts"
        let absR = abs(r)
        return absR >= 5000 ? "geradeaus" : String(format: "%.0f m (%@)", absR, side)
    }
}

/// Compact 2-column grid of boolean vehicle state indicators (active flags highlighted).
private struct FlagGrid: View {
    let items: [(String, Bool, Color)]
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { name, on, tint in
                HStack(spacing: 6) {
                    Circle()
                        .fill(on ? tint : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                    Text(name)
                        .font(.caption.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(on ? tint.opacity(0.14) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}
