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
            marker
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
