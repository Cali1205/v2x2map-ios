import CarPlay
import MapKit
import SwiftUI

/// CarPlay navigation scene: our own MKMapView drawn into the CarPlay window, with
/// CPMapTemplate supplying the system controls on top.
/// Only shown in the car once Apple has granted `com.apple.developer.carplay-maps`
/// and the app is signed with V2X2/CarPlay.entitlements (see README).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var window: CPWindow?
    private let mapVC = CarMapViewController()

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.window = window
        window.rootViewController = mapVC

        let template = CPMapTemplate()
        template.mapButtons = [
            mapButton("plus.magnifyingglass") { [mapVC] in mapVC.zoom(by: 0.5) },
            mapButton("minus.magnifyingglass") { [mapVC] in mapVC.zoom(by: 2) },
            mapButton("location.north.line.fill") { [mapVC] in mapVC.recenter() },
        ]
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Meldungen") { [weak self] _ in self?.showHazards() },
        ]
        mapVC.onNewHazard = { [weak template] s, distance in
            guard let template, template.currentNavigationAlert == nil else { return }
            let sub = distance.map { String(format: "%.0f m · ITS-G5", $0) } ?? "ITS-G5"
            let alert = CPNavigationAlert(titleVariants: [s.title], subtitleVariants: [sub],
                                          image: UIImage(systemName: "exclamationmark.triangle.fill"),
                                          primaryAction: CPAlertAction(title: "OK", style: .cancel) { _ in },
                                          secondaryAction: nil, duration: 8)
            template.present(navigationAlert: alert, animated: true)
        }
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        self.interfaceController = nil
        self.window = nil
    }

    private func mapButton(_ symbol: String, _ action: @escaping () -> Void) -> CPMapButton {
        let b = CPMapButton { _ in action() }
        b.image = UIImage(systemName: symbol)
        return b
    }

    /// List of current hazards (DENM) and traffic lights (SPATEM), nearest first.
    private func showHazards() {
        let model = AppModel.shared
        let rows = model.mapStations
            .filter { $0.msgType == .denm || $0.msgType == .spatem }
            .map { s in (s, s.coordinate.flatMap { model.location.distance(to: $0) } ?? .infinity) }
            .sorted { $0.1 < $1.1 }
            .prefix(CPListTemplate.maximumItemCount)
            .map { s, d in
                CPListItem(text: s.title,
                           detailText: d.isFinite ? String(format: "%@ · %.0f m", s.msgType.label, d) : s.msgType.label,
                           image: UIImage(systemName: s.msgType.symbol))
            }
        let list = CPListTemplate(title: "Meldungen", sections: [CPListSection(items: Array(rows))])
        list.emptyViewTitleVariants = ["Keine Meldungen in der Nähe"]
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }
}

/// Map shown on the car screen. Syncs station annotations from AppModel once per second.
final class CarMapViewController: UIViewController, MKMapViewDelegate {
    private let map = MKMapView()
    private var annotations: [UInt64: StationAnnotation] = [:]
    private var alerted: Set<UInt64> = []
    private var timer: Timer?
    /// Called once per new hazard (DENM) within 2 km, or of unknown distance.
    var onNewHazard: (Station, Double?) -> Void = { _, _ in }

    override func viewDidLoad() {
        super.viewDidLoad()
        map.frame = view.bounds
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = self
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "station")
        view.addSubview(map)
        recenter()
        // shortcut: polls instead of observing AppModel; fine at 1 Hz, switch to withObservationTracking if it ever lags.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sync() }
    }

    func zoom(by factor: Double) {
        var r = map.region
        r.span.latitudeDelta = min(max(r.span.latitudeDelta * factor, 0.0005), 90)
        r.span.longitudeDelta = min(max(r.span.longitudeDelta * factor, 0.0005), 180)
        map.setRegion(r, animated: true)
    }

    func recenter() {
        map.setUserTrackingMode(.followWithHeading, animated: true)
    }

    private func sync() {
        let stations = AppModel.shared.mapStations
        let live = Set(stations.map(\.id))
        for (id, a) in annotations where !live.contains(id) {
            map.removeAnnotation(a)
            annotations[id] = nil
        }
        for s in stations {
            guard let c = s.coordinate else { continue }
            if s.msgType == .denm, !alerted.contains(s.id) {
                let d = AppModel.shared.location.distance(to: c)
                if (d ?? 0) <= 2000 { alerted.insert(s.id); onNewHazard(s, d) }
            }
            if let a = annotations[s.id] {
                a.update(s, c)
                (map.view(for: a) as? MKMarkerAnnotationView).map { style($0, a) }
            } else {
                let a = StationAnnotation(s, c)
                annotations[s.id] = a
                map.addAnnotation(a)
            }
        }
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let a = annotation as? StationAnnotation else { return nil }
        let v = mapView.dequeueReusableAnnotationView(withIdentifier: "station", for: a) as! MKMarkerAnnotationView
        style(v, a)
        return v
    }

    private func style(_ v: MKMarkerAnnotationView, _ a: StationAnnotation) {
        v.markerTintColor = a.tint
        v.glyphImage = UIImage(systemName: a.symbol)
        v.displayPriority = a.msgType == .cam ? .defaultHigh : .required
    }
}

final class StationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var msgType: MsgType
    var tint: UIColor = .gray
    var symbol: String = "circle"

    init(_ s: Station, _ c: CLLocationCoordinate2D) {
        coordinate = c
        msgType = s.msgType
        super.init()
        update(s, c)
    }

    func update(_ s: Station, _ c: CLLocationCoordinate2D) {
        coordinate = c
        title = s.title
        msgType = s.msgType
        symbol = s.msgType.symbol
        switch s.spatPhase {
        case .red: tint = .systemRed
        case .yellow: tint = .systemYellow
        case .green: tint = .systemGreen
        default: tint = UIColor(s.msgType.color)
        }
    }
}
