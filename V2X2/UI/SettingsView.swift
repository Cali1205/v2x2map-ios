import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.ttlMinutes) private var ttl = 10
    @AppStorage(Settings.geiger) private var geiger = false
    @AppStorage(Settings.showTrack) private var showTrack = true
    @AppStorage(Settings.hideInactive) private var hideInactive = false
    @AppStorage(Settings.hideOwnVehicle) private var hideOwnVehicle = false
    @AppStorage(Settings.buttonLabels) private var buttonLabels = true
    @AppStorage(Settings.autoRecord) private var autoRecord = false
    @AppStorage(Settings.mqttOn) private var mqttOn = false
    @AppStorage(Settings.mqttURL) private var mqttURL = Settings.defaultBroker
    @AppStorage(Settings.mqttUser) private var mqttUser = ""
    @AppStorage(Settings.mqttNode) private var mqttNode = ""
    @State private var mqttPassword = MqttPassword.get()
    @State private var cycle: [Int] = [1000, 1000, 500, 400]
    @State private var showRecordings = false

    private let cycleLabels = ["Suche: Sniff", "Suche: BLE", "Verbunden: Sniff", "Verbunden: BLE"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Marker-Lebensdauer: \(ttl) min", value: $ttl, in: 1...1440, step: ttl < 10 ? 1 : 5)
                    Toggle("Inaktive Objekte ausblenden", isOn: $hideInactive)
                    Toggle("Eigenes Fahrzeug ausblenden", isOn: $hideOwnVehicle)
                    if let egoId = model.ego.egoId, let s = model.stations[egoId] {
                        LabeledContent("Erkanntes Fahrzeug") {
                            Text("\(s.idHex)\(model.ego.pseudonymSwitches > 0 ? " (\(model.ego.pseudonymSwitches)× gewechselt)" : "")")
                                .font(.caption.monospaced())
                        }
                    }
                    Toggle("Button-Beschriftung anzeigen", isOn: $buttonLabels)
                    Toggle("Eigene Spur anzeigen", isOn: $showTrack)
                    Button("Spur löschen") { model.location.clearTrack() }
                } header: {
                    Text("Karte")
                } footer: {
                    Text("Objekte, die gerade senden, pulsieren. Ohne Empfang seit 15 s werden sie grau (oder ausgeblendet) und verschwinden nach der Marker-Lebensdauer. Das eigene Fahrzeug wird anhand der Bewegung erkannt und bei ID-Wechsel übernommen.")
                }
                Section {
                    Toggle("Geigerzähler-Modus", isOn: $geiger)
                } footer: {
                    Text("Klick + Vibration pro Frame, Warnton bei Gefahrenmeldung (DENM).")
                }
                Section {
                    Toggle("Immer automatisch aufzeichnen", isOn: $autoRecord)
                    Button {
                        showRecordings = true
                    } label: {
                        Label("Aufgezeichnete Fahrten", systemImage: "play.circle")
                    }
                    if let f = model.recorder.lastFile {
                        ShareLink(item: f) { Label("Letzte: \(f.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                } header: {
                    Text("Aufnahme & Wiedergabe")
                } footer: {
                    Text("Startet die PCAP- und GPS-Aufzeichnung direkt beim App-Start. Wenn deaktiviert, wird beim Start gefragt. Dateien liegen auch in der Dateien-App.")
                }
                Section {
                    Toggle("An MQTT-Broker senden", isOn: $mqttOn)
                    if mqttOn {
                        TextField("Broker", text: $mqttURL, prompt: Text(Settings.defaultBroker))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Benutzer (optional)", text: $mqttUser)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Passwort (optional)", text: $mqttPassword)
                        TextField("Node-ID", text: $mqttNode,
                                  prompt: Text(model.defaultMqttNodeId ?? "MAC des Empfängers"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        LabeledContent("Status", value: mqttStatus)
                    }
                } header: {
                    Text("MQTT")
                } footer: {
                    Text("Sendet jeden empfangenen Rohframe an its/<Node-ID>/packet, dazu online/offline an its/<Node-ID>/status. "
                         + "mqtts:// = verschlüsselt (Port 8883), mqtt:// = unverschlüsselt (1883). "
                         + "Läuft weiter, solange die App per Bluetooth im Hintergrund aktiv ist.")
                }
                .onChange(of: mqttOn) { applyMqtt() }
                .onSubmit { applyMqtt() }
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
            .onDisappear { applyMqtt() }
            .onAppear { if let c = model.receiverConfig { cycle = c } }
            .onChange(of: model.receiverConfig ?? []) { _, c in if c.count == 4 { cycle = c } }
            .onChange(of: model.replay.isActive) { _, active in if active { dismiss() } }
            .sheet(isPresented: $showRecordings) { RecordingsView() }
        }
    }

    /// Not on every keystroke, or each character would reconnect.
    private func applyMqtt() {
        if mqttPassword != MqttPassword.get() { MqttPassword.set(mqttPassword) }
        model.syncMqtt()
    }

    private var mqttStatus: String {
        switch model.mqtt.state {
        case .off: "aus"
        case .connecting: "verbinde …"
        case .connected: "verbunden · \(model.mqtt.sent) gesendet"
        case .failed(let msg): msg
        }
    }
}
