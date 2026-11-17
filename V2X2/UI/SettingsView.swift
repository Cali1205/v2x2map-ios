import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.ttlMinutes) private var ttl = 60
    @AppStorage(Settings.geiger) private var geiger = false
    @AppStorage(Settings.showTrack) private var showTrack = true
    @State private var cycle: [Int] = [1000, 1000, 500, 400]

    private let cycleLabels = ["Suche: Sniff", "Suche: BLE", "Verbunden: Sniff", "Verbunden: BLE"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Karte") {
                    Stepper("Marker-Lebensdauer: \(ttl) min", value: $ttl, in: 1...1440, step: ttl < 10 ? 1 : 5)
                    Toggle("Eigene Spur anzeigen", isOn: $showTrack)
                    Button("Spur löschen") { model.location.clearTrack() }
                }
                Section {
                    Toggle("Geigerzähler-Modus", isOn: $geiger)
                } footer: {
                    Text("Klick + Vibration pro Frame, Warnton bei Gefahrenmeldung (DENM).")
                }
                Section("Aufnahme") {
                    if let f = model.recorder.lastFile {
                        ShareLink(item: f) { Label(f.lastPathComponent, systemImage: "square.and.arrow.up") }
                    } else {
                        Text("Noch keine Aufnahme. PCAP-Dateien liegen auch in der Dateien-App.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Status", value: "\(model.state)")
                    if let mac = model.receiverMac { LabeledContent("MAC", value: mac) }
                    if model.receiverConfig != nil {
                        ForEach(0..<4, id: \.self) { i in
                            Stepper("\(cycleLabels[i]): \(cycle[i]) ms", value: $cycle[i], in: 100...60000, step: 50)
                        }
                        Button("An Empfänger senden") { model.writeReceiverConfig(cycle) }
                    }
                    Button("Anderen Empfänger suchen", role: .destructive) { model.forgetReceiver() }
                } header: {
                    Text("Empfänger")
                } footer: {
                    Text("Der ESP32 wechselt zwischen Funk-Mithören (Sniff) und Bluetooth. Mehr Sniff-Zeit = mehr Frames, mehr BLE-Zeit = weniger Verzögerung.")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .onAppear { if let c = model.receiverConfig { cycle = c } }
            .onChange(of: model.receiverConfig ?? []) { _, c in if c.count == 4 { cycle = c } }
        }
    }
}
