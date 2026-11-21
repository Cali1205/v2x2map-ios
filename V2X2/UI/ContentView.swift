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
    @State private var didHandleLaunch = false
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
            guard !didHandleLaunch else { return }
            didHandleLaunch = true
            if autoRecord {
                model.startRecording()
            } else if !model.recorder.isRecording, !model.replay.isActive {
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

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer()
            Text("\(model.itsFrames) ITS · \(model.totalFrames) total")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal)
    }

    private var text: String {
        if model.replay.loading { return "Lade Aufnahme …" }
        if model.replay.isActive { return "Wiedergabe · \(model.replay.name ?? "")" }
        switch model.state {
        case .off: return "Bluetooth aus"
        case .unauthorized: return "Bluetooth nicht erlaubt"
        case .scanning: return "Suche ITS-G5-RX …"
        case .connecting: return "Verbinde …"
        case .connected: return "Empfänger verbunden"
        }
    }

    private var color: Color {
        if model.replay.loading { return .orange }
        if model.replay.isActive { return .blue }
        switch model.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        default: return .red
        }
    }
}

struct ReplayBar: View {
    @Environment(AppModel.self) private var model
    let onFitRoute: () -> Void
    @State private var scrubbing = false
    @State private var wasPlaying = false
    @State private var scrubValue = 0.0

    var body: some View {
        let duration = max(1, model.replay.duration)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(model.replay.position?.formatted(date: .omitted, time: .standard) ?? "--:--:--")
                    .font(.caption.monospacedDigit().weight(.semibold))
                if let s = model.replay.fix?.speedMps {
                    Text(String(format: "· %.0f km/h", s * 3.6))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(format(scrubbing ? scrubValue : model.replay.elapsed)) / \(format(model.replay.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { model.replay.stop() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Wiedergabe beenden")
            }

            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : min(model.replay.elapsed, duration) },
                    set: { v in
                        scrubValue = v
                        model.replay.seek(toElapsed: v)
                    }
                ),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        wasPlaying = model.replay.isPlaying
                        scrubValue = model.replay.elapsed
                        scrubbing = true
                        model.replay.pause()
                    } else {
                        scrubbing = false
                        if wasPlaying { model.replay.play() }
                    }
                }
            )
            .disabled(model.replay.duration <= 0)

            HStack(spacing: 22) {
                Button { model.replay.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                }
                .accessibilityLabel("15 Sekunden zurück")

                Button {
                    model.replay.isPlaying ? model.replay.pause() : model.replay.play()
                } label: {
                    Image(systemName: model.replay.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .accessibilityLabel(model.replay.isPlaying ? "Pause" : "Abspielen")

                Button { model.replay.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title3)
                }
                .accessibilityLabel("15 Sekunden vor")

                Spacer()

                Menu {
                    ForEach(Replayer.speeds, id: \.self) { s in
                        Button {
                            model.replay.speed = s
                        } label: {
                            if model.replay.speed == s {
                                Label("\(Int(s))×", systemImage: "checkmark")
                            } else {
                                Text("\(Int(s))×")
                            }
                        }
                    }
                } label: {
                    Text("\(Int(model.replay.speed))×")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                .accessibilityLabel("Geschwindigkeit")

                if model.replay.recording?.region != nil {
                    Button(action: onFitRoute) {
                        Image(systemName: "viewfinder").font(.title3)
                    }
                    .accessibilityLabel("Auf Fahrt zoomen")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

enum MarkerGeometry {
    /// Vehicle heading on screen in degrees clockwise from screen-up (0° = up, 90° = right, 180° = down, 270° = left).
    static func screenHeading(vehicleHeading: Double, mapHeading: Double) -> Double {
        var d = (vehicleHeading - mapHeading).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// True when an active side blinker rotates into the upper arc of the marker circle
    /// where the ICH / VehicleBadges stack sits.
    static func hasUpperBlinker(screenHeading: Double, blinkLeft: Bool, blinkRight: Bool) -> Bool {
        let s = sin(screenHeading * .pi / 180)
        // Left blinker sits at (-r, 0) before CW rotation -> y' = -r * sin(theta), upper when sin > 0.35.
        // Right blinker sits at (+r, 0) before CW rotation -> y' = +r * sin(theta), upper when sin < -0.35.
        return (blinkLeft && s > 0.35) || (blinkRight && s < -0.35)
    }
}

struct ReplayCarMarker: View {
    let fix: Recording.Fix
    var mapHeading: Double = 0

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(.blue).frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .shadow(radius: 3)
                if let course = fix.courseDeg {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(MarkerGeometry.screenHeading(vehicleHeading: course, mapHeading: mapHeading)))
                } else {
                    Circle().fill(.white).frame(width: 8, height: 8)
                }
            }
            if let speed = fix.speedMps {
                Text(String(format: "%.0f km/h", speed * 3.6))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.65), in: Capsule())
            }
        }
    }
}

struct StationMarker: View {
    let station: Station
    var isOwn = false
    var mapHeading: Double = 0

    private var displayHeading: Double? {
        guard station.msgType == .cam, station.stationType != 15, let h = station.headingDeg else { return nil }
        return MarkerGeometry.screenHeading(vehicleHeading: h, mapHeading: mapHeading)
    }

    var body: some View {
        // Re-evaluates isActive every 1 s without new frames arriving.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let active = station.isActive
            let blinkerHeading = displayHeading ?? 0
            let upperBlinker = active && MarkerGeometry.hasUpperBlinker(
                screenHeading: blinkerHeading,
                blinkLeft: station.blinkLeft,
                blinkRight: station.blinkRight
            )
            // Extras are overlays so the circle stays centred on the vehicle's position.
            // MapKit places the annotation title (speed / cause) below the marker, so status
            // badges sit above the circle to avoid overlapping the speed label.
            marker
                .frame(width: 40, height: 40)
                .overlay {
                    if active, station.braking {
                        Circle().stroke(.red, lineWidth: 4).frame(width: 34, height: 34)
                            .shadow(color: .red, radius: station.emergencyBraking ? 8 : 4)
                    } else if active, station.hasSiren || station.hasLightBar {
                        Circle().stroke(.blue, lineWidth: 4).frame(width: 34, height: 34)
                            .shadow(color: .blue, radius: 6)
                    }
                }
                .overlay {
                    ZStack {
                        BlinkerArrow(left: true, on: active && station.blinkLeft)
                            .offset(x: -22)
                        BlinkerArrow(left: false, on: active && station.blinkRight)
                            .offset(x: 22)
                    }
                    .frame(width: 40, height: 40)
                    .rotationEffect(.degrees(blinkerHeading))
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 2) {
                        if isOwn {
                            Text("ICH")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.teal, in: Capsule())
                        }
                        if active, station.hasSiren || station.hasLightBar {
                            Text(station.hasSiren ? "SIRENE" : "BLAULICHT")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.blue, in: Capsule())
                        }
                        if active { VehicleBadges(station: station) }
                    }
                    .fixedSize()
                    .alignmentGuide(.top) { d in d[.bottom] + (upperBlinker ? 10 : 3) }
                }
            .saturation(active ? 1 : 0)
            .opacity(active ? 1 : 0.45)
            .background { if active { PulseRing(color: fill) } }
        }
        .accessibilityLabel("\(isOwn ? "Eigenes Fahrzeug, " : "")\(station.stationClassLabel), \(station.title)\(station.isActive ? "" : ", inaktiv")")
    }

    private var marker: some View {
        ZStack {
            Circle().fill(fill).frame(width: 30, height: 30)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            if let h = displayHeading {
                Image(systemName: "location.north.fill")
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(h))
            } else {
                Image(systemName: station.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var fill: Color {
        if isOwn { return .teal }
        if station.isEmergency { return .indigo }
        switch station.spatPhase {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        default: return station.msgType.color
        }
    }
}

/// Expanding ring behind stations that are still sending.
struct PulseRing: View {
    let color: Color

    var body: some View {
        Circle().stroke(color, lineWidth: 3).frame(width: 30, height: 30)
            .phaseAnimator([false, true]) { v, on in
                v.scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 0.8)
            } animation: { on in on ? .easeOut(duration: 1.4) : nil }
    }
}

/// Orange turn-signal triangle on the vehicle's left/right side, flashing at ~1.5 Hz like a real indicator.
struct BlinkerArrow: View {
    let left: Bool
    let on: Bool

    var body: some View {
        Image(systemName: left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.orange)
            .shadow(color: .orange, radius: 3)
            .opacity(on ? 1 : 0)
            .phaseAnimator(on ? [1.0, 0.15] : [1.0]) { v, o in v.opacity(o) } animation: { _ in .linear(duration: 0.33) }
            .id(on)  // restart the flashing cycle when the indicator switches
    }
}

/// Small capsule above a vehicle: accelerating, assistance systems and notable lights.
struct VehicleBadges: View {
    let station: Station

    var body: some View {
        let icons = items
        if !icons.isEmpty {
            HStack(spacing: 3) {
                ForEach(icons, id: \.self) { i in
                    if i.count <= 3, !i.contains(".") {
                        Text(i).font(.system(size: 9, weight: .heavy))
                    } else {
                        Image(systemName: i).font(.system(size: 10, weight: .bold))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: Capsule())
        }
    }

    /// SF Symbol names, or short text labels (≤ 3 chars).
    private var items: [String] {
        guard let c = station.cam else { return [] }
        var i: [String] = []
        if station.accelerating { i.append("arrow.up.circle.fill") }
        if let k = c.control {
            if k.contains(.collisionWarning) { i.append("exclamationmark.triangle.fill") }
            if k.contains(.acc) { i.append("ACC") }
            if k.contains(.cruiseControl) { i.append("CC") }
            if k.contains(.speedLimiter) { i.append("LIM") }
        }
        if let l = c.lights {
            if l.contains(.highBeam) { i.append("headlight.high.beam.fill") }
            if l.contains(.fog) { i.append("headlight.fog.fill") }
            if l.contains(.reverse) { i.append("R") }
        }
        return i
    }
}
