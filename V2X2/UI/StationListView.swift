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
                                        ownRole: model.ownRole(for: s.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .listStyle(.plain)
                        } else {
                            StationTableView(
                                stations: stations,
                                distance: { s in s.coordinate.flatMap { model.distance(to: $0) } },
                                ownRole: { s in model.ownRole(for: s.id) },
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
}


private struct StationRow: View {
    let station: Station
    let distance: Double?
    let ownRole: StationOwnRole?

    var body: some View {
        let active = station.isActive
        HStack(spacing: 10) {
            StationIcon(symbol: station.symbol, fill: iconColor.opacity(active ? 1 : 0.35))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(station.stationClassLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let ownRole {
                        OwnRoleBadge(role: ownRole, style: .row)
                    }
                    if station.hasSiren || station.hasLightBar {
                        EmergencyBadge(station: station, style: .row)
                    }
                    if let sec = station.secured { Text(sec ? "🔒" : "🔓").font(.caption2) }
                }
                HStack(spacing: 4) {
                    MsgTypeBadges(station: station, font: .system(size: 9, weight: .bold), fillOpacity: 0.16)
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
                    Text(d.distanceText())
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
        station.tint(isOwn: ownRole == .current)
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
