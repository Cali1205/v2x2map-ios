import MapKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapHeading: Double = 0
    @State private var showList = false
    @State private var showRecordings = false
    @State private var showSettings = false
    @State private var showRecordPrompt = false
    @State private var didAskRecording = false
    @State private var selectedStation: StationSelection?
    @AppStorage(Settings.showTrack) private var showTrack = true
    @AppStorage(Settings.mapStyle) private var mapStyle = 0
    @AppStorage(Settings.buttonLabels) private var buttonLabels = true
    @AppStorage(Settings.autoRecord) private var autoRecord = false

    var body: some View {
        let stations = model.mapStations
        let hasOwnStationMarker = model.ego.egoId.map { id in
            stations.contains { $0.id == id && $0.isActive }
        } ?? false
        Map(position: $position) {
            if model.replay.isActive {
                if showTrack, model.replay.remainingTrack.count > 1 {
                    MapPolyline(coordinates: model.replay.remainingTrack).stroke(.blue.opacity(0.25), lineWidth: 3)
                }
                if showTrack, model.replay.playedTrack.count > 1 {
                    MapPolyline(coordinates: model.replay.playedTrack).stroke(.blue.opacity(0.85), lineWidth: 4)
                }
                if !hasOwnStationMarker, let fix = model.replay.fix {
                    Annotation("Aufzeichnung", coordinate: fix.coordinate) {
                        ReplayCarMarker(fix: fix, mapHeading: mapHeading)
                    }
                }
            } else {
                UserAnnotation()
                if showTrack, model.location.track.count > 1 {
                    MapPolyline(coordinates: model.location.track).stroke(.blue.opacity(0.7), lineWidth: 4)
                }
            }
            ForEach(stations) { s in
                Annotation(s.title, coordinate: s.coordinate!) {
                    Button {
                        selectedStation = StationSelection(id: s.id)
                    } label: {
                        StationMarker(station: s, isOwn: model.ego.egoId == s.id, mapHeading: mapHeading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(style)
        .onMapCameraChange(frequency: .continuous) { context in
            let h = context.camera.heading
            if EgoDetector.angleDiff(h, mapHeading) >= 0.5 {
                mapHeading = h
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
        .safeAreaInset(edge: .top) { StatusBar() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.replay.isActive {
                    ReplayBar(onFitRoute: fitReplayRegion)
                }
                bottomBar
            }
            .alert("Fahrt aufzeichnen?", isPresented: $showRecordPrompt) {
                Button("Aufzeichnen") { model.startRecording() }
                Button("Immer aufzeichnen") {
                    autoRecord = true
                    model.startRecording()
                }
                Button("Nicht jetzt", role: .cancel) {}
            } message: {
                Text("Möchtest du die aktuelle Fahrt (ITS-G5-Frames und GPS-Spur) aufzeichnen?")
            }
        }
        .sheet(isPresented: $showList) {
            StationListView(onFocus: focusOnCoordinate)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedStation) { sel in
            StationDetailView(stationId: sel.id, onFocus: focusOnCoordinate)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showRecordings) { RecordingsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            if autoRecord { model.startRecording() }
        }
        // Ask once per app session, only after the ESP32 receiver is actually connected.
        .onChange(of: model.state) { _, state in
            guard state == .connected, !didAskRecording else { return }
            didAskRecording = true
            if !model.recorder.isRecording, !model.replay.isActive {
                showRecordPrompt = true
            }
        }
        .onChange(of: model.replay.name) { _, name in
            if name != nil { fitReplayRegion() }
        }
        .onChange(of: model.replay.isActive) { _, active in
            if !active { position = .userLocation(fallback: .automatic) }
        }
        .alert("Wiedergabe fehlgeschlagen", isPresented: Binding(
            get: { !showRecordings && model.replay.error != nil },
            set: { if !$0 { model.replay.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.replay.error = nil }
        } message: {
            Text(model.replay.error ?? "")
        }
    }

    private func fitReplayRegion() {
        if let r = model.replay.recording?.region {
            position = .region(r)
        }
    }

    private func focusOnCoordinate(_ coordinate: CLLocationCoordinate2D) {
        position = .camera(MapCamera(centerCoordinate: coordinate, distance: 600))
    }

    private var style: MapStyle {
        switch mapStyle {
        case 1: .hybrid(elevation: .realistic)
        case 2: .imagery(elevation: .realistic)
        default: .standard(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button { showList = true } label: {
                barItem("Liste", systemImage: "list.bullet", badge: "\(model.stations.count)")
            }
            Button {
                if let fix = model.replay.fix {
                    position = .camera(MapCamera(centerCoordinate: fix.coordinate, distance: 1200, heading: fix.courseDeg ?? 0))
                } else {
                    // Heading-up follow (Android "compass mode").
                    position = .userLocation(followsHeading: true, fallback: .automatic)
                }
            } label: {
                barItem("Kompass", systemImage: "location.north.line.fill")
            }
            Menu {
                Picker("Karte", selection: $mapStyle) {
                    Text("Standard").tag(0)
                    Text("Hybrid").tag(1)
                    Text("Satellit").tag(2)
                }
            } label: {
                barItem("Karte", systemImage: "square.3.layers.3d")
            }
            Button {
                model.toggleRecording()
            } label: {
                barItem(model.recorder.isRecording ? "Stopp" : "Aufnahme",
                        systemImage: model.recorder.isRecording ? "stop.circle.fill" : "record.circle",
                        tint: model.recorder.isRecording ? .red : nil)
            }
            .accessibilityLabel(model.recorder.isRecording ? "Aufnahme stoppen" : "PCAP aufnehmen")
            Button { showRecordings = true } label: {
                barItem("Fahrten",
                        systemImage: model.replay.isActive ? "play.circle.fill" : "play.circle",
                        tint: model.replay.isActive ? .blue : nil)
            }
            Button { showSettings = true } label: {
                barItem("Optionen", systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, buttonLabels ? 9 : 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func barItem(_ title: String, systemImage: String, badge: String? = nil, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                if let badge {
                    Text(badge)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            .foregroundStyle(tint ?? Color.accentColor)
            if buttonLabels {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint ?? .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
