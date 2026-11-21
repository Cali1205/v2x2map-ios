import SwiftUI

/// One row per station, expandable to its last 20 frames (Android "grouped frame log").
struct StationListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List(model.stations.values.sorted { $0.lastSeen > $1.lastSeen }) { s in
                DisclosureGroup {
                    ForEach(s.recent) { f in FrameRow(frame: f) }
                } label: {
                    StationRow(station: s,
                               distance: s.coordinate.flatMap { model.distance(to: $0) },
                               ownRole: ownRole(for: s.id))
                }
            }
            .overlay {
                if model.stations.isEmpty {
                    ContentUnavailableView("Noch nichts empfangen", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Sobald der Empfänger ITS-G5-Meldungen sieht, erscheinen sie hier."))
                }
            }
            .navigationTitle("Stationen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Leeren", role: .destructive) { model.clear() }
            }
        }
    }

    private func ownRole(for id: UInt64) -> StationRow.OwnRole? {
        if model.ego.egoId == id { return .current }
        if model.ego.isSupersededOwnVehicle(id) { return .past }
        return nil
    }
}

private struct StationRow: View {
    enum OwnRole { case current, past }

    let station: Station
    let distance: Double?
    let ownRole: OwnRole?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: station.msgType.symbol)
                .foregroundStyle(ownRole == .current ? Color.teal : station.msgType.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.msgType.rawValue).font(.headline)
                    if let ownRole {
                        Text(ownRole == .current ? "ICH" : "ICH (alt)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(ownRole == .current ? Color.teal : Color.secondary, in: Capsule())
                    }
                    if let sec = station.secured { Text(sec ? "🔒" : "🔓").font(.caption) }
                    Text(station.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !station.statusText.isEmpty {
                    Text(station.statusText).font(.caption).foregroundStyle(station.braking ? Color.red : Color.primary)
                }
                Text("\(station.idHex) · \(station.count)× · \(station.lastSeen.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let d = distance {
                Text(d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000))
                    .font(.caption.monospacedDigit())
            }
        }
    }
}

private struct FrameRow: View {
    let frame: Frame

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(frame.received.formatted(date: .omitted, time: .standard)) · \(frame.decoded.msgType.rawValue) · \(frame.payload.count) B")
                .font(.caption)
            Text(frame.hexPreview())
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }
}
