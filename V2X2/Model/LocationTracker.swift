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
        // Keep tracking while the app is in the background (UIBackgroundModes: location);
        // "while using" permission is enough because updates start in the foreground.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func distance(to c: CLLocationCoordinate2D) -> CLLocationDistance? {
        last?.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    func clearTrack() { track.removeAll() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        last = l
        track.append(l.coordinate)
        if track.count > 10_000 { track.removeFirst(1_000) }
        onLocation?(l)
    }

    /// Called for every accepted fix (the recorder writes it to the track file).
    @ObservationIgnored var onLocation: ((CLLocation) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }
}
