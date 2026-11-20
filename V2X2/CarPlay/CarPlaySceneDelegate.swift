import CarPlay
import MapKit
import SwiftUI

/// CarPlay "Driving Task" scene. Driving-task apps may not draw their own map, so the car shows
/// Apple's point-of-interest map with the nearest hazards, traffic lights and vehicles, a list
/// sorted by distance, and an alert for every new hazard warning.
/// Only shown in the car once Apple has granted `com.apple.developer.carplay-driving-task`
/// and the app is signed with V2X2/CarPlay.entitlements (see README).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPPointOfInterestTemplateDelegate {
    private var interfaceController: CPInterfaceController?
    private let mapTemplate = CPPointOfInterestTemplate(title: "In der Nähe", pointsOfInterest: [], selectedIndex: NSNotFound)
    private let listTemplate = CPListTemplate(title: "Meldungen", sections: [])
    private var timer: Timer?
    private var alerted: Set<UInt64> = []
    private var shownIds: [UInt64] = []

    /// CarPlay limits the point-of-interest template to 12 pins.
    private static let maxPins = 12

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        mapTemplate.pointOfInterestDelegate = self
        mapTemplate.tabImage = UIImage(systemName: "map")
        listTemplate.tabImage = UIImage(systemName: "list.bullet")
        listTemplate.emptyViewTitleVariants = ["Keine Meldungen in der Nähe"]
        let tabs = CPTabBarTemplate(templates: [mapTemplate, listTemplate])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        refresh()
        // shortcut: polls AppModel; fine at this rate, switch to withObservationTracking if it ever lags.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController) {
        timer?.invalidate()
        timer = nil
        self.interfaceController = nil
    }

    func pointOfInterestTemplate(_ template: CPPointOfInterestTemplate, didChangeMapRegion region: MKCoordinateRegion) {}

    /// Hazards first, then traffic lights, braking vehicles, other vehicles; each group nearest first.
    private func nearby() -> [(station: Station, coordinate: CLLocationCoordinate2D, distance: Double?)] {
        let model = AppModel.shared
        func rank(_ s: Station) -> Int {
            switch s.msgType {
            case .denm: 0
            case .spatem: 1
            case .cam: s.braking ? 2 : 3
            default: 4
            }
        }
        return model.mapStations
            .filter { $0.isActive || $0.msgType == .denm }
            .compactMap { s in s.coordinate.map { (s, $0, model.location.distance(to: $0)) } }
            .sorted { (rank($0.0), $0.2 ?? .infinity) < (rank($1.0), $1.2 ?? .infinity) }
    }

    private func refresh() {
        let items = nearby()
        alertNewHazards(items)

        let pins = Array(items.prefix(Self.maxPins))
        let ids = pins.map(\.station.id)
        // Vehicles move, so pins are always re-set; keep the user's selected pin selected.
        let sel = mapTemplate.selectedIndex
        let selectedId = shownIds.indices.contains(sel) ? shownIds[sel] : nil
        shownIds = ids
        mapTemplate.setPointsOfInterest(pins.map(poi), selectedIndex: selectedId.flatMap { ids.firstIndex(of: $0) } ?? NSNotFound)

        let rows = items.prefix(CPListTemplate.maximumItemCount).map { s, _, d in
            CPListItem(text: s.title, detailText: detail(s, d), image: pinImage(s))
        }
        listTemplate.updateSections([CPListSection(items: Array(rows))])
    }

    private func poi(_ item: (station: Station, coordinate: CLLocationCoordinate2D, distance: Double?)) -> CPPointOfInterest {
        let s = item.station
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
        mapItem.name = s.title
        return CPPointOfInterest(location: mapItem, title: s.title, subtitle: detail(s, item.distance),
                                  summary: s.statusText.isEmpty ? nil : s.statusText,
                                  detailTitle: s.msgType.label, detailSubtitle: detail(s, item.distance),
                                  detailSummary: s.statusText.isEmpty ? nil : s.statusText,
                                  pinImage: pinImage(s))
    }

    private func detail(_ s: Station, _ d: Double?) -> String {
        guard let d else { return s.msgType.label }
        let dist = d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000)
        return "\(s.msgType.label) · \(dist)"
    }

    private func pinImage(_ s: Station) -> UIImage? {
        let color: UIColor
        switch s.spatPhase {
        case .red: color = .systemRed
        case .yellow: color = .systemYellow
        case .green: color = .systemGreen
        default: color = s.braking ? .systemRed : UIColor(s.msgType.color)
        }
        return UIImage(systemName: s.msgType.symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// One alert per new hazard (DENM) within 2 km or of unknown distance; closes itself after 8 s.
    private func alertNewHazards(_ items: [(station: Station, coordinate: CLLocationCoordinate2D, distance: Double?)]) {
        guard let ic = interfaceController, ic.presentedTemplate == nil,
              let hazard = items.first(where: { $0.station.msgType == .denm && !alerted.contains($0.station.id) && ($0.distance ?? 0) <= 2000 })
        else { return }
        alerted.insert(hazard.station.id)
        let alert = CPAlertTemplate(titleVariants: ["\(hazard.station.title) · \(detail(hazard.station, hazard.distance))", hazard.station.title],
                                    actions: [CPAlertAction(title: "OK", style: .cancel) { [weak ic] _ in ic?.dismissTemplate(animated: true, completion: nil) }])
        ic.presentTemplate(alert, animated: true, completion: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak ic] in
            if ic?.presentedTemplate === alert { ic?.dismissTemplate(animated: true, completion: nil) }
        }
    }
}
