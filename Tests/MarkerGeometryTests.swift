import XCTest
@testable import V2X2

final class MarkerGeometryTests: XCTestCase {
    func testScreenHeadingAccountsForMapRotation() {
        XCTAssertEqual(MarkerGeometry.screenHeading(vehicleHeading: 0, mapHeading: 0), 0, accuracy: 0.001)
        XCTAssertEqual(MarkerGeometry.screenHeading(vehicleHeading: 90, mapHeading: 0), 90, accuracy: 0.001)
        XCTAssertEqual(MarkerGeometry.screenHeading(vehicleHeading: 90, mapHeading: 90), 0, accuracy: 0.001)
        XCTAssertEqual(MarkerGeometry.screenHeading(vehicleHeading: 0, mapHeading: 90), 270, accuracy: 0.001)
        XCTAssertEqual(MarkerGeometry.screenHeading(vehicleHeading: 10, mapHeading: 350), 20, accuracy: 0.001)
        XCTAssertEqual(MarkerGeometry.screenHeading(vehicleHeading: 350, mapHeading: 10), 340, accuracy: 0.001)
    }

    func testUpperBlinkerDetectionMatchesVehicleOrientation() {
        // Driving straight up or down on screen -> side blinkers sit horizontally left/right, not at top.
        XCTAssertFalse(MarkerGeometry.hasUpperBlinker(screenHeading: 0, blinkLeft: true, blinkRight: true))
        XCTAssertFalse(MarkerGeometry.hasUpperBlinker(screenHeading: 180, blinkLeft: true, blinkRight: true))

        // Driving right on screen (90°) -> left blinker is on top, right blinker is on bottom.
        XCTAssertTrue(MarkerGeometry.hasUpperBlinker(screenHeading: 90, blinkLeft: true, blinkRight: false))
        XCTAssertFalse(MarkerGeometry.hasUpperBlinker(screenHeading: 90, blinkLeft: false, blinkRight: true))

        // Driving left on screen (270°) -> right blinker is on top, left blinker is on bottom.
        XCTAssertFalse(MarkerGeometry.hasUpperBlinker(screenHeading: 270, blinkLeft: true, blinkRight: false))
        XCTAssertTrue(MarkerGeometry.hasUpperBlinker(screenHeading: 270, blinkLeft: false, blinkRight: true))

        // Hazard lights when driving East/West put one blinker on top.
        XCTAssertTrue(MarkerGeometry.hasUpperBlinker(screenHeading: 90, blinkLeft: true, blinkRight: true))
        XCTAssertTrue(MarkerGeometry.hasUpperBlinker(screenHeading: 270, blinkLeft: true, blinkRight: true))

        // No active blinker -> never upper.
        XCTAssertFalse(MarkerGeometry.hasUpperBlinker(screenHeading: 90, blinkLeft: false, blinkRight: false))
    }
}
