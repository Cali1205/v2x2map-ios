import SwiftUI

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
                Text(speed.speedKmhText)
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
                            OwnRoleBadge(role: .current, style: .marker)
                        }
                        if active, station.hasSiren || station.hasLightBar {
                            EmergencyBadge(station: station, style: .marker)
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
        station.tint(isOwn: isOwn, phase: true)
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
