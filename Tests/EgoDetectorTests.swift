import CoreLocation
import XCTest
@testable import V2X2

final class EgoDetectorTests: XCTestCase {
    private func camFrame(at time: Date, coord: CLLocationCoordinate2D, speed: Double, heading: Double,
                          stationId: UInt64, type: Int = 5) -> Frame {
        let d = ItsG5Decoder.Decoded(
            etherType: ItsG5Decoder.etherTypeItsG5,
            msgType: .cam,
            stationId: stationId,
            stationType: type,
            latitude: coord.latitude,
            longitude: coord.longitude,
            headingDeg: heading,
            speedMps: speed,
            btpDstPort: 2001
        )
        return Frame(id: Int(time.timeIntervalSince1970 * 10), received: time, sec: 0, usec: 0, payload: [], decoded: d)
    }

    func testDetectsMovingOwnVehicleAndIgnoresOncomingAndTrailing() {
        let detector = EgoDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = CLLocationCoordinate2D(latitude: 48.5, longitude: 9.2)

        for i in 0..<8 {
            let t = t0.addingTimeInterval(Double(i))
            let myCoord = OwnFix.offset(origin, meters: 20.0 * Double(i), bearingDeg: 0)
            let own = OwnFix(time: t, coordinate: myCoord, speedMps: 20.0, courseDeg: 0, accuracyM: 6)

            // Own car within 4 m, same speed & heading
            let egoCoord = OwnFix.offset(myCoord, meters: 4.0, bearingDeg: 90)
            detector.observe(frame: camFrame(at: t, coord: egoCoord, speed: 20.2, heading: 1.0, stationId: 0xAA),
                             stationId: 0xAA, own: own)

            // Oncoming car passing at distance 5 m, heading 180°
            let oncomingCoord = OwnFix.offset(myCoord, meters: Double(3 - i) * 35.0, bearingDeg: 0)
            detector.observe(frame: camFrame(at: t, coord: oncomingCoord, speed: 20.0, heading: 180.0, stationId: 0xBB),
                             stationId: 0xBB, own: own)

            // Trailing car 60 m behind at same speed & heading
            let trailingCoord = OwnFix.offset(myCoord, meters: 60.0, bearingDeg: 180)
            detector.observe(frame: camFrame(at: t, coord: trailingCoord, speed: 20.0, heading: 0.0, stationId: 0xCC),
                             stationId: 0xCC, own: own)
        }

        XCTAssertEqual(detector.egoId, 0xAA)
        XCTAssertFalse(detector.isOwnVehicle(0xBB))
        XCTAssertFalse(detector.isOwnVehicle(0xCC))
    }

    func testDoesNotLockWhileStationaryAndKeepsLockWhenStopped() {
        let detector = EgoDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = CLLocationCoordinate2D(latitude: 48.5, longitude: 9.2)

        // Neighbor parked right beside us while we haven't moved yet
        for i in 0..<8 {
            let t = t0.addingTimeInterval(Double(i))
            let own = OwnFix(time: t, coordinate: origin, speedMps: 0, courseDeg: nil, accuracyM: 8)
            let neighbor = OwnFix.offset(origin, meters: 5, bearingDeg: 90)
            detector.observe(frame: camFrame(at: t, coord: neighbor, speed: 0, heading: 0, stationId: 0x10),
                             stationId: 0x10, own: own)
        }
        XCTAssertNil(detector.egoId)

        // Now drive away while 0x20 moves with us
        for i in 10..<17 {
            let t = t0.addingTimeInterval(Double(i))
            let myCoord = OwnFix.offset(origin, meters: 15.0 * Double(i - 9), bearingDeg: 45)
            let own = OwnFix(time: t, coordinate: myCoord, speedMps: 15.0, courseDeg: 45, accuracyM: 5)
            detector.observe(frame: camFrame(at: t, coord: myCoord, speed: 15.0, heading: 45, stationId: 0x20),
                             stationId: 0x20, own: own)
        }
        XCTAssertEqual(detector.egoId, 0x20)

        // Stop at a red light: lock should persist
        let stopCoord = OwnFix.offset(origin, meters: 15.0 * 7, bearingDeg: 45)
        for i in 17..<25 {
            let t = t0.addingTimeInterval(Double(i))
            let own = OwnFix(time: t, coordinate: stopCoord, speedMps: 0, courseDeg: nil, accuracyM: 5)
            detector.observe(frame: camFrame(at: t, coord: stopCoord, speed: 0, heading: 45, stationId: 0x20),
                             stationId: 0x20, own: own)
        }
        XCTAssertEqual(detector.egoId, 0x20)
    }

    func testPseudonymChangeHandoff() {
        let detector = EgoDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = CLLocationCoordinate2D(latitude: 48.5, longitude: 9.2)

        // Establish 0x1111 as ego driving east at 25 m/s
        for i in 0..<7 {
            let t = t0.addingTimeInterval(Double(i))
            let c = OwnFix.offset(origin, meters: 25.0 * Double(i), bearingDeg: 90)
            let own = OwnFix(time: t, coordinate: c, speedMps: 25.0, courseDeg: 90, accuracyM: 5)
            detector.observe(frame: camFrame(at: t, coord: c, speed: 25.0, heading: 90, stationId: 0x1111),
                             stationId: 0x1111, own: own)
        }
        XCTAssertEqual(detector.egoId, 0x1111)

        // 0x1111 stops at t = 6; new pseudonym 0x2222 starts at t = 6.3, 7.0, 7.5
        for dt in [6.3, 7.0, 7.5] {
            let t = t0.addingTimeInterval(dt)
            let c = OwnFix.offset(origin, meters: 25.0 * dt, bearingDeg: 90)
            let own = OwnFix(time: t, coordinate: c, speedMps: 25.0, courseDeg: 90, accuracyM: 5)
            detector.observe(frame: camFrame(at: t, coord: c, speed: 25.0, heading: 90, stationId: 0x2222),
                             stationId: 0x2222, own: own)
        }

        XCTAssertEqual(detector.egoId, 0x2222)
        XCTAssertTrue(detector.isSupersededOwnVehicle(0x1111))
        XCTAssertEqual(detector.pseudonymSwitches, 1)
    }

    func testDoesNotHandoffIfOldIdKeepsTransmitting() {
        let detector = EgoDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = CLLocationCoordinate2D(latitude: 48.5, longitude: 9.2)

        for i in 0..<7 {
            let t = t0.addingTimeInterval(Double(i))
            let c = OwnFix.offset(origin, meters: 20.0 * Double(i), bearingDeg: 0)
            let own = OwnFix(time: t, coordinate: c, speedMps: 20.0, courseDeg: 0, accuracyM: 5)
            detector.observe(frame: camFrame(at: t, coord: c, speed: 20.0, heading: 0, stationId: 0x1111),
                             stationId: 0x1111, own: own)
        }
        XCTAssertEqual(detector.egoId, 0x1111)

        // Another car 0x3333 appears nearby at t = 6.2, but 0x1111 continues transmitting at 6.8 and 7.5
        for dt in [6.2, 6.8, 7.5] {
            let t = t0.addingTimeInterval(dt)
            let c = OwnFix.offset(origin, meters: 20.0 * dt, bearingDeg: 0)
            let own = OwnFix(time: t, coordinate: c, speedMps: 20.0, courseDeg: 0, accuracyM: 5)
            if dt >= 6.8 {
                detector.observe(frame: camFrame(at: t, coord: c, speed: 20.0, heading: 0, stationId: 0x1111),
                                 stationId: 0x1111, own: own)
            }
            let near = OwnFix.offset(c, meters: 15, bearingDeg: 90)
            detector.observe(frame: camFrame(at: t, coord: near, speed: 20.0, heading: 0, stationId: 0x3333),
                             stationId: 0x3333, own: own)
        }

        XCTAssertEqual(detector.egoId, 0x1111)
        XCTAssertEqual(detector.pseudonymSwitches, 0)
        XCTAssertFalse(detector.isSupersededOwnVehicle(0x1111))
    }
}
