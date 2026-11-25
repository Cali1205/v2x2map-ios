import CoreLocation
import Observation

/// Own position + driven track (blue line on the map) and distance to stations.
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private(set) var last: CLLocation?
    private(set) var track: [CLLocationCoordinate2D] = []
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.activityType = .automotiveNavigation
        // Background tracking is switched on by AppModel only while the ESP32 is connected (see backgroundUpdates).
        manager.pausesLocationUpdatesAutomatically = false
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// Keep GPS running in the background (UIBackgroundModes: location). In the foreground GPS always runs;
    /// "while using" permission is enough because updates were started in the foreground.
    @ObservationIgnored var backgroundUpdates = false {
        didSet {
            guard backgroundUpdates != oldValue else { return }
            manager.allowsBackgroundLocationUpdates = backgroundUpdates
            manager.showsBackgroundLocationIndicator = backgroundUpdates
            if backgroundUpdates { manager.startUpdatingLocation() }
        }
    }

    @ObservationIgnored private var recentFixes: [OwnFix] = []

    func distance(to c: CLLocationCoordinate2D) -> CLLocationDistance? {
        last?.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    func ownFix(at time: Date) -> OwnFix? {
        guard let base = recentFixes.last(where: { $0.time <= time }) ?? recentFixes.last else { return nil }
        return base.projected(to: time)
    }

    func clearTrack() { track.removeAll() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        last = l
        track.append(l.coordinate)
        if track.count > 10_000 { track.removeFirst(1_000) }
        recentFixes.append(OwnFix(
            time: l.timestamp,
            coordinate: l.coordinate,
            speedMps: l.speed >= 0 ? l.speed : nil,
            courseDeg: l.course >= 0 ? l.course : nil,
            accuracyM: l.horizontalAccuracy
        ))
        if recentFixes.count > 60 { recentFixes.removeFirst(recentFixes.count - 60) }
        onLocation?(l)
    }

    /// Called for every accepted fix (the recorder writes it to the track file).
    @ObservationIgnored var onLocation: ((CLLocation) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }
}
