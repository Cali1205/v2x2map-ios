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
    private let pins = CarPlayPinRenderer()
    /// Flipped every refresh; drives the pin "animation" (see CarPlayPinRenderer).
    private var tick = false
    /// Station ids in the order first seen, newest first. Stays in the list after a station goes inactive.
    private var history: [UInt64] = []
    private var listSignature: [HistoryRow] = []
    private var mapSignature: MapSignature?

    private struct MapPinSignature: Equatable {
        let id: UInt64
        let latE5: Int
        let lonE5: Int
        let headingBucket: Int
        let symbol: String
        let msgType: MsgType
        let spatPhase: SpatTemParser.Phase?
        let isEmergency: Bool
        let braking: Bool
        let title: String
        let detail: String
        let detailTitle: String
        let statusText: String
    }

    private struct MapSignature: Equatable {
        let pins: [MapPinSignature]
        let selectedId: UInt64?
    }

    private struct HistoryRow: Equatable {
        let id: UInt64
        let title: String
        let detail: String
        let symbol: String
        let msgType: MsgType
        let spatPhase: SpatTemParser.Phase?
        let braking: Bool
        let isEmergency: Bool
        let active: Bool
    }

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
        // shortcut: polls AppModel once a second (also drives the pin animation); switch to withObservationTracking if it ever lags.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
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
            case .cam: s.isEmergency ? 1 : (s.braking ? 2 : 3)
            default: 4
            }
        }
        return model.mapStations
            .filter { ($0.isActive || $0.msgType == .denm) && !model.ego.isOwnVehicle($0.id) }
            .compactMap { s in s.coordinate.map { (s, $0, model.distance(to: $0)) } }
            .sorted { (rank($0.0), $0.2 ?? .infinity) < (rank($1.0), $1.2 ?? .infinity) }
    }

    private func refresh() {
        tick.toggle()
        let items = nearby()
        alertNewHazards(items)

        let top = Array(items.prefix(Self.maxPins))
        let ids = top.map(\.station.id)
        // Skip re-setting pins when nothing visible changed and no shown pin animates; keep the user's selection.
        let sel = mapTemplate.selectedIndex
        let selectedId = shownIds.indices.contains(sel) ? shownIds[sel] : nil
        let sig = MapSignature(
            pins: top.map { item in
                let s = item.station
                return MapPinSignature(
                    id: s.id,
                    latE5: Int((item.coordinate.latitude * 1e5).rounded()),
                    lonE5: Int((item.coordinate.longitude * 1e5).rounded()),
                    headingBucket: CarPlayPinRenderer.headingBucket(for: s) ?? -1,
                    symbol: s.symbol,
                    msgType: s.msgType,
                    spatPhase: s.spatPhase,
                    isEmergency: s.isEmergency,
                    braking: s.braking,
                    title: s.title,
                    detail: detail(s, item.distance),
                    detailTitle: s.msgType == .cam ? s.stationClassLabel : s.msgType.label,
                    statusText: s.statusText
                )
            },
            selectedId: selectedId
        )
        if sig != mapSignature || top.contains(where: { CarPlayPinRenderer.animates($0.station) }) {
            mapSignature = sig
            shownIds = ids
            mapTemplate.setPointsOfInterest(top.map(poi), selectedIndex: selectedId.flatMap { ids.firstIndex(of: $0) } ?? NSNotFound)
        }

        refreshHistory()
    }

    /// "Meldungen" as history: new stations go on top, quiet ones stay (grey) until AppModel prunes them.
    private func refreshHistory() {
        let model = AppModel.shared
        let live = model.stations.values.filter {
            $0.coordinate != nil && !model.ego.isOwnVehicle($0.id) && !model.ego.isSupersededOwnVehicle($0.id)
        }
        let byId = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        history.removeAll { byId[$0] == nil }
        let known = Set(history)
        history.insert(contentsOf: live.filter { !known.contains($0.id) }.sorted { $0.lastSeen > $1.lastSeen }.map(\.id), at: 0)

        // Cap only the display: dropping ids from `history` would make them look new again.
        let shown = history.prefix(CPListTemplate.maximumItemCount).compactMap { byId[$0] }
        let rows = shown.map { s -> HistoryRow in
            let d = s.coordinate.flatMap { model.distance(to: $0) }.map(bucketedDistance)
            return HistoryRow(
                id: s.id,
                title: s.title,
                detail: s.isActive ? detail(s, d) : "\(detail(s, d)) · \(ageText(s))",
                symbol: s.symbol,
                msgType: s.msgType,
                spatPhase: s.spatPhase,
                braking: s.braking,
                isEmergency: s.isEmergency,
                active: s.isActive
            )
        }
        guard rows != listSignature else { return }
        listSignature = rows
        let items = zip(rows, shown).map { row, s in
            CPListItem(text: row.title, detailText: row.detail, image: pins.image(for: s, tick: true, selected: false, inactive: !row.active, heading: false))
        }
        listTemplate.updateSections([CPListSection(items: items)])
    }

    /// Rounds to 50 m below 1 km and 0.1 km above so list rows stay stable across minor GPS jitter.
    private func bucketedDistance(_ d: Double) -> Double {
        d < 1000 ? (d / 50).rounded() * 50 : (d / 100).rounded() * 100
    }

    /// "vor < 1 min" / "vor 2 min" / "vor 1 h", on the virtual clock so replays behave like live mode.
    private func ageText(_ s: Station) -> String {
        let secs = max(0, Int(Clock.now.timeIntervalSince(s.lastSeen)))
        if secs < 60 { return "vor < 1 min" }  // minute resolution keeps the list signature stable
        if secs < 3600 { return "vor \(secs / 60) min" }
        return "vor \(secs / 3600) h"
    }

    private func poi(_ item: (station: Station, coordinate: CLLocationCoordinate2D, distance: Double?)) -> CPPointOfInterest {
        let s = item.station
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
        mapItem.name = s.title
        let poi = CPPointOfInterest(location: mapItem, title: s.title, subtitle: detail(s, item.distance),
                                  summary: s.statusText.isEmpty ? nil : s.statusText,
                                  detailTitle: s.msgType == .cam ? s.stationClassLabel : s.msgType.label,
                                  detailSubtitle: detail(s, item.distance),
                                  detailSummary: s.statusText.isEmpty ? nil : s.statusText,
                                  pinImage: pins.image(for: s, tick: tick, selected: false))
        poi.selectedPinImage = pins.image(for: s, tick: tick, selected: true)
        return poi
    }

    private func detail(_ s: Station, _ d: Double?) -> String {
        let kind = s.msgType == .cam ? s.stationClassLabel : s.msgType.label
        guard let d else { return kind }
        return "\(kind) · \(d.distanceText())"
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
