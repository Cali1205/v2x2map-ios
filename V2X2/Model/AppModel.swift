import AudioToolbox
import CoreLocation
import Observation
import UIKit

/// A sender seen on air: a vehicle (CAM), an RSU/traffic light (SPATEM/MAPEM) or a hazard (DENM).
struct Station: Identifiable {
    let id: UInt64
    var msgType: MsgType
    var stationType: Int?
    var coordinate: CLLocationCoordinate2D?
    var headingDeg: Double?
    var speedMps: Double?
    var secured: Bool?
    var spatPhase: SpatTemParser.Phase?
    var denmCause: DenmParser.Cause?
    var cam: CamParser.State?
    var lastSeen: Date
    var count = 0
    var recent: [Frame] = []  // newest first, max 20 (like the Android log)

    /// Still sending: heard within the last few seconds (CAMs come at 1–10 Hz, the receiver
    /// alternates radio and Bluetooth, so allow some gaps).
    var isActive: Bool { Clock.now.timeIntervalSince(lastSeen) < 15 }

    // Vehicle state from CAMs. Thresholds: ~0.1 g counts as clearly braking/accelerating.
    var braking: Bool { cam?.control?.contains(.brakePedal) == true || (cam?.longAccel ?? 0) <= -1.0 }
    var emergencyBraking: Bool { cam?.control?.contains(.emergencyBrake) == true || (cam?.longAccel ?? 0) <= -4.0 }
    var accelerating: Bool { !braking && (cam?.longAccel ?? 0) >= 1.0 }
    var blinkLeft: Bool { cam?.lights?.contains(.leftTurn) == true }
    var blinkRight: Bool { cam?.lights?.contains(.rightTurn) == true }

    /// Short German status line, e.g. "bremst · Blinker links · ACC · Fernlicht".
    var statusText: String {
        guard let c = cam else { return "" }
        var t: [String] = []
        if emergencyBraking { t.append("Notbremsung") } else if braking { t.append("bremst") } else if accelerating { t.append("beschleunigt") }
        if let a = c.longAccel, abs(a) >= 0.3 { t.append(String(format: "%+.1f m/s²", a)) }
        switch (blinkLeft, blinkRight) {
        case (true, true): t.append("Warnblinker")
        case (true, false): t.append("Blinker links")
        case (false, true): t.append("Blinker rechts")
        default: break
        }
        if let k = c.control {
            if k.contains(.collisionWarning) { t.append("Kollisionswarnung") }
            if k.contains(.acc) { t.append("ACC") }
            if k.contains(.cruiseControl) { t.append("Tempomat") }
            if k.contains(.speedLimiter) { t.append("Limiter") }
        }
        if let l = c.lights {
            if l.contains(.highBeam) { t.append("Fernlicht") }
            if l.contains(.fog) { t.append("Nebellicht") }
            if l.contains(.reverse) { t.append("Rückfahrlicht") }
        }
        return t.joined(separator: " · ")
    }

    var idHex: String { String(format: "%012llX", id & 0xFFFF_FFFF_FFFF) }

    var title: String {
        if let c = denmCause { return "\(c.label) \(c.sublabel)".trimmingCharacters(in: .whitespaces) }
        if let s = speedMps, msgType == .cam { return String(format: "%.0f km/h", s * 3.6) }
        return msgType.rawValue
    }
}

/// Shared state for the phone UI and the CarPlay scene. Everything runs on the main queue.
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var stations: [UInt64: Station] = [:]
    private(set) var state: Receiver.State = .off
    private(set) var totalFrames = 0
    private(set) var itsFrames = 0
    private(set) var receiverConfig: [Int]?
    private(set) var receiverMac: String?
    let location = LocationTracker()
    let recorder = PcapRecorder()
    let mqtt = MqttClient()
    let replay = Replayer()
    let ego = EgoDetector()

    @ObservationIgnored private let receiver = Receiver()
    @ObservationIgnored private var reader = FrameReader()
    @ObservationIgnored private var pruneTimer: Timer?

    var markerTTL: TimeInterval { TimeInterval(max(1, UserDefaults.standard.integer(forKey: Settings.ttlMinutes))) * 60 }

    private init() {
        UserDefaults.standard.register(defaults: [Settings.ttlMinutes: 10, Settings.showTrack: true,
                                                  Settings.buttonLabels: true, Settings.mqttURL: Settings.defaultBroker])
        receiver.onState = { [weak self] in self?.state = $0 }
        receiver.onConfig = { [weak self] in self?.receiverConfig = $0 }
        receiver.onMac = { [weak self] in self?.receiverMac = $0; self?.syncMqtt() }
        receiver.onData = { [weak self] data in
            guard let self else { return }
            for f in reader.feed(data) { ingest(f) }
        }
        location.onLocation = { [weak self] in self?.recorder.write(location: $0) }
        replay.onFrame = { [weak self] f, quiet in self?.apply(f, quiet: quiet) }
        replay.onReset = { [weak self] in self?.resetStations() }
        replay.lookback = { [weak self] in self?.markerTTL ?? 600 }
        syncMqtt()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.prune() }
    }

    /// Stations with a position that were seen within the marker TTL (only active ones if so set).
    var mapStations: [Station] {
        let cutoff = Clock.now.addingTimeInterval(-markerTTL)
        let hideInactive = UserDefaults.standard.bool(forKey: Settings.hideInactive)
        let hideOwn = UserDefaults.standard.bool(forKey: Settings.hideOwnVehicle)
        return stations.values.filter { s in
            guard s.coordinate != nil, s.lastSeen >= cutoff else { return false }
            if ego.isSupersededOwnVehicle(s.id) { return false }
            if hideOwn && s.id == ego.egoId { return false }
            return !hideInactive || s.isActive
        }
    }

    /// Distance from the own position: the recorded one during a replay, else the live GPS.
    func distance(to c: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard replay.isActive else { return location.distance(to: c) }
        guard let f = replay.fix else { return nil }
        return CLLocation(latitude: f.coordinate.latitude, longitude: f.coordinate.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    func startRecording() {
        guard !recorder.isRecording else { return }
        // Start the track with the current fix if it is fresh, so the replay has a position right away.
        let fresh = location.last.flatMap { Date().timeIntervalSince($0.timestamp) < 30 ? $0 : nil }
        recorder.start(at: fresh)
    }

    func toggleRecording() {
        if recorder.isRecording { return recorder.stop() }
        startRecording()
    }

    func writeReceiverConfig(_ v: [Int]) { receiver.writeConfig(v) }
    func forgetReceiver() { receiver.forget() }
    func clear() { stations.removeAll(); ego.reset() }

    /// Applies the MQTT settings; call after they change. Node ID defaults to the receiver MAC.
    func syncMqtt() {
        let d = UserDefaults.standard
        let node = d.string(forKey: Settings.mqttNode)?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? receiverMac?.replacingOccurrences(of: ":", with: "").lowercased() ?? "ios"
        guard d.bool(forKey: Settings.mqttOn),
              let cfg = MqttClient.Config(url: d.string(forKey: Settings.mqttURL) ?? "", user: d.string(forKey: Settings.mqttUser) ?? "",
                                          password: MqttPassword.get(), node: node)
        else { return mqtt.stop() }
        mqtt.start(cfg)
    }

    /// A live frame from the receiver. During a replay it is still recorded and forwarded,
    /// but the map shows the replay only.
    func ingest(_ f: Frame) {
        recorder.write(f)
        mqtt.publish(Data(f.payload))
        guard !replay.isActive else { return }
        apply(f, quiet: false)
    }

    /// Updates the station model (live or replayed frame). `quiet`: no Geiger tick (fast rebuild after a seek).
    private func apply(_ f: Frame, quiet: Bool) {
        totalFrames += 1
        let d = f.decoded
        guard let id = d.stationId ?? f.transmitter else { return }
        if d.etherType == ItsG5Decoder.etherTypeItsG5 { itsFrames += 1 }

        var s = stations[id] ?? Station(id: id, msgType: d.msgType, lastSeen: f.received)
        s.lastSeen = f.received
        s.count += 1
        s.recent.insert(f, at: 0)
        if s.recent.count > 20 { s.recent.removeLast() }
        if d.msgType != .unknown { s.msgType = d.msgType }
        if let v = d.stationType { s.stationType = v }
        if let lat = d.latitude, let lon = d.longitude { s.coordinate = .init(latitude: lat, longitude: lon) }
        if let v = d.headingDeg { s.headingDeg = v }
        if let v = d.speedMps { s.speedMps = v }
        if let v = d.secured { s.secured = v }
        if let v = d.spatPhase, v != .unknown { s.spatPhase = v }
        if let v = d.denmCause { s.denmCause = v }
        if let c = d.cam {
            // Lights only come in low-frequency CAMs and the control bits are optional: keep the last known.
            var m = c
            m.control = c.control ?? s.cam?.control
            m.lights = c.lights ?? s.cam?.lights
            s.cam = m
        }
        stations[id] = s

        let own = replay.isActive ? replay.ownFix(at: f.received) : location.ownFix(at: f.received)
        ego.observe(frame: f, stationId: id, own: own)

        if !quiet { Geiger.tick(hazard: d.msgType == .denm) }
    }

    /// Replay start / seek / stop: the map starts from scratch.
    private func resetStations() {
        stations.removeAll()
        ego.reset()
        totalFrames = 0
        itsFrames = 0
    }

    private func prune() {
        let cutoff = Clock.now.addingTimeInterval(-markerTTL)
        stations = stations.filter { $0.value.lastSeen >= cutoff }
        ego.prune(now: Clock.now)
    }
}

enum Settings {
    static let ttlMinutes = "marker_ttl_min"
    static let geiger = "geiger"
    static let showTrack = "show_track"
    static let mapStyle = "map_style"
    static let hideInactive = "hide_inactive"
    static let hideOwnVehicle = "hide_own_vehicle"
    static let buttonLabels = "button_labels"
    static let autoRecord = "auto_record"
    static let mqttOn = "mqtt_on"
    static let mqttURL = "mqtt_url"
    static let mqttUser = "mqtt_user"
    static let mqttNode = "mqtt_node"
    static let defaultBroker = "mqtts://cits1.opentrafficmap.org:8883"  // same default as the Android app
}

/// Audio + haptic tick per frame, distinct alert on DENM (Android "Geiger-counter mode").
enum Geiger {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let alert = UINotificationFeedbackGenerator()

    static func tick(hazard: Bool) {
        guard UserDefaults.standard.bool(forKey: Settings.geiger) else { return }
        if hazard {
            AudioServicesPlaySystemSound(1005)
            alert.notificationOccurred(.warning)
        } else {
            AudioServicesPlaySystemSound(1104)
            light.impactOccurred()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
