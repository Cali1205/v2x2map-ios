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
    var lastSeen: Date
    var count = 0
    var recent: [Frame] = []  // newest first, max 20 (like the Android log)

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

    @ObservationIgnored private let receiver = Receiver()
    @ObservationIgnored private var reader = FrameReader()
    @ObservationIgnored private var pruneTimer: Timer?

    var markerTTL: TimeInterval { TimeInterval(max(1, UserDefaults.standard.integer(forKey: Settings.ttlMinutes))) * 60 }

    private init() {
        UserDefaults.standard.register(defaults: [Settings.ttlMinutes: 60, Settings.showTrack: true,
                                                  Settings.mqttURL: Settings.defaultBroker])
        receiver.onState = { [weak self] in self?.state = $0 }
        receiver.onConfig = { [weak self] in self?.receiverConfig = $0 }
        receiver.onMac = { [weak self] in self?.receiverMac = $0; self?.syncMqtt() }
        receiver.onData = { [weak self] data in
            guard let self else { return }
            for f in reader.feed(data) { ingest(f) }
        }
        syncMqtt()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.prune() }
    }

    /// Stations with a position that were seen within the marker TTL.
    var mapStations: [Station] {
        let cutoff = Date().addingTimeInterval(-markerTTL)
        return stations.values.filter { $0.coordinate != nil && $0.lastSeen >= cutoff }
    }

    func writeReceiverConfig(_ v: [Int]) { receiver.writeConfig(v) }
    func forgetReceiver() { receiver.forget() }
    func clear() { stations.removeAll() }

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

    func ingest(_ f: Frame) {
        totalFrames += 1
        recorder.write(f)
        mqtt.publish(Data(f.payload))
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
        stations[id] = s

        Geiger.tick(hazard: d.msgType == .denm)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-markerTTL)
        stations = stations.filter { $0.value.lastSeen >= cutoff }
    }
}

enum Settings {
    static let ttlMinutes = "marker_ttl_min"
    static let geiger = "geiger"
    static let showTrack = "show_track"
    static let mapStyle = "map_style"
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
