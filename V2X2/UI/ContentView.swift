import MapKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showList = false
    @State private var showSettings = false
    @AppStorage(Settings.showTrack) private var showTrack = true
    @AppStorage(Settings.mapStyle) private var mapStyle = 0

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
            if showTrack, model.location.track.count > 1 {
                MapPolyline(coordinates: model.location.track).stroke(.blue.opacity(0.7), lineWidth: 4)
            }
            ForEach(model.mapStations) { s in
                Annotation(s.title, coordinate: s.coordinate!) {
                    StationMarker(station: s)
                }
            }
        }
        .mapStyle(style)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
        .safeAreaInset(edge: .top) { StatusBar() }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showList) { StationListView().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var style: MapStyle {
        switch mapStyle {
        case 1: .hybrid(elevation: .realistic)
        case 2: .imagery(elevation: .realistic)
        default: .standard(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 22) {
            Button { showList = true } label: {
                Label("\(model.stations.count)", systemImage: "list.bullet")
            }
            Button {
                // Heading-up follow (Android "compass mode").
                position = .userLocation(followsHeading: true, fallback: .automatic)
            } label: {
                Image(systemName: "location.north.line.fill")
            }
            Menu {
                Picker("Karte", selection: $mapStyle) {
                    Text("Standard").tag(0)
                    Text("Hybrid").tag(1)
                    Text("Satellit").tag(2)
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
            }
            Button {
                model.recorder.isRecording ? model.recorder.stop() : model.recorder.start()
            } label: {
                Image(systemName: model.recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(model.recorder.isRecording ? Color.red : Color.accentColor)
            }
            .accessibilityLabel(model.recorder.isRecording ? "Aufnahme stoppen" : "PCAP aufnehmen")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .font(.title)
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 8)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline.weight(.medium))
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
        switch model.state {
        case .off: "Bluetooth aus"
        case .unauthorized: "Bluetooth nicht erlaubt"
        case .scanning: "Suche ITS-G5-RX …"
        case .connecting: "Verbinde …"
        case .connected: "Empfänger verbunden"
        }
    }

    private var color: Color {
        switch model.state {
        case .connected: .green
        case .connecting, .scanning: .orange
        default: .red
        }
    }
}

struct StationMarker: View {
    let station: Station

    var body: some View {
        // Re-evaluates isActive every 2 s without new frames arriving.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let active = station.isActive
            // Extras are overlays so the circle stays centred on the vehicle's position.
            marker
                .overlay {
                    if active, station.braking {
                        Circle().stroke(.red, lineWidth: 4).frame(width: 34, height: 34)
                            .shadow(color: .red, radius: station.emergencyBraking ? 8 : 4)
                    }
                }
                .overlay(alignment: .leading) { BlinkerArrow(left: true, on: active && station.blinkLeft).offset(x: -15) }
                .overlay(alignment: .trailing) { BlinkerArrow(left: false, on: active && station.blinkRight).offset(x: 15) }
                .overlay(alignment: .bottom) {
                    if active { VehicleBadges(station: station).fixedSize().offset(y: 20) }
                }
            .saturation(active ? 1 : 0)
            .opacity(active ? 1 : 0.45)
            .background { if active { PulseRing(color: fill) } }
        }
        .accessibilityLabel("\(station.msgType.label), \(station.title)\(station.isActive ? "" : ", inaktiv")")
    }

    private var marker: some View {
        ZStack {
            Circle().fill(fill).frame(width: 30, height: 30)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            if station.msgType == .cam, let h = station.headingDeg {
                Image(systemName: "location.north.fill")
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(h))
            } else {
                Image(systemName: station.msgType.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var fill: Color {
        switch station.spatPhase {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        default: station.msgType.color
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

/// Orange turn-signal triangle next to the marker, flashing at ~1.5 Hz like a real indicator.
struct BlinkerArrow: View {
    let left: Bool
    let on: Bool

    var body: some View {
        Image(systemName: left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.orange)
            .shadow(color: .orange, radius: 3)
            .opacity(on ? 1 : 0)
            .phaseAnimator(on ? [1.0, 0.15] : [1.0]) { v, o in v.opacity(o) } animation: { _ in .linear(duration: 0.33) }
            .id(on)  // restart the flashing cycle when the indicator switches
    }
}

/// Small capsule below a vehicle: accelerating, assistance systems and notable lights.
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
