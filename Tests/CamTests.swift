import XCTest
@testable import V2X2

final class CamTests: XCTestCase {
    private struct BitWriter {
        var bits = ""

        mutating func put(_ v: Int, _ n: Int) {
            precondition(v >= 0)
            let raw = String(v, radix: 2)
            let padded = String(repeating: "0", count: max(0, n - raw.count)) + raw
            bits += String(padded.suffix(n))
        }

        mutating func constrained(_ v: Int, _ lo: Int, _ hi: Int) {
            let range = hi - lo + 1
            let width = range <= 1 ? 0 : Int.bitWidth - (range - 1).leadingZeroBitCount
            if width > 0 { put(v - lo, width) }
        }

        func finishWithBtp() -> [UInt8] {
            var padded = bits
            while padded.count % 8 != 0 { padded += "0" }
            let body = stride(from: 0, to: padded.count, by: 8).map { i -> UInt8 in
                let s = padded.index(padded.startIndex, offsetBy: i)
                return UInt8(padded[s..<padded.index(s, offsetBy: 8)], radix: 2)!
            }
            return [0x07, 0xD1, 0, 0] + body
        }
    }

    /// Builds an ITS PDU (from the BTP header) for a CAM with the given HF/LF values, bit by bit.
    private func cam(speed: Int, heading: Int, accel: Int, control: Int?, lights: Int?) -> [UInt8] {
        var w = BitWriter()
        w.put(2, 8); w.put(2, 8); w.put(0x1234_5678, 32)       // ItsPduHeader
        w.put(0, 16)                                           // generationDeltaTime
        w.put(0, 1); w.put(lights == nil ? 0 : 1, 1); w.put(0, 1) // ext, LF, special
        w.put(0, 1); w.put(5, 8); w.put(0, 123)                // basic container
        w.put(0, 1); w.put(0, 1)                               // HF choice basicVehicle
        w.put(control == nil ? 0 : 1, 1); w.put(0, 6)          // optionals
        w.put(heading, 12); w.put(1, 7); w.put(speed, 14); w.put(1, 7)
        w.put(0, 2); w.put(45, 13); w.put(18, 6)
        w.put(accel + 160, 9); w.put(1, 7)
        w.put(0, 14); w.put(0, 3); w.put(0, 20)
        if let c = control { w.put(c, 7) }
        if let l = lights { w.put(0, 1); w.put(0, 4); w.put(l, 8) }
        return w.finishWithBtp()
    }

    func testHighAndLowFrequency() {
        let s = CamParser.parse(cam(speed: 1389, heading: 900, accel: -25, control: 0b100_0100, lights: 0b1010_0001), btpOff: 0)
        XCTAssertEqual(s?.speedMps, 13.89)
        XCTAssertEqual(s?.headingDeg, 90)
        XCTAssertEqual(s?.longAccel, -2.5)
        XCTAssertEqual(s?.control, [.brakePedal, .acc])
        XCTAssertEqual(s?.lights, [.lowBeam, .leftTurn, .parking])
    }

    func testOptionalContainersMissing() {
        let s = CamParser.parse(cam(speed: 0, heading: 3601, accel: 161, control: nil, lights: nil), btpOff: 0)
        XCTAssertEqual(s?.speedMps, 0)
        XCTAssertNil(s?.headingDeg)
        XCTAssertNil(s?.longAccel)
        XCTAssertNil(s?.control)
        XCTAssertNil(s?.lights)
    }

    func testFullTelemetryAndDimensions() {
        var w = BitWriter()
        w.put(2, 8); w.put(2, 8); w.put(0x1122_3344, 32)       // ItsPduHeader
        w.put(1000, 16)                                        // generationDeltaTime
        w.put(0, 1); w.put(1, 1); w.put(0, 1)                  // ext=0, LF=1, SV=0
        // BasicContainer: ext(1), stationType(8)=6 (Bus), ReferencePosition(123)
        w.put(0, 1); w.put(6, 8)
        w.constrained(484_905_079, -900_000_000, 900_000_001)
        w.constrained(92_075_820, -1_800_000_000, 1_800_000_001)
        w.put(0, 36)                                           // PosConfidenceEllipse
        w.constrained(42_860, -100_000, 800_001)               // 428.60 m
        w.put(0, 4)                                            // altConf
        // HF choice basicVehicle + optionals (accCtl, lane, steer, latAcc, vertAcc, perf = 1; toll = 0)
        w.put(0, 1); w.put(0, 1)
        w.put(1, 1); w.put(1, 1); w.put(1, 1); w.put(1, 1); w.put(1, 1); w.put(1, 1); w.put(0, 1)
        w.put(1800, 12); w.put(1, 7)                           // heading 180.0°
        w.put(1500, 14); w.put(1, 7)                           // speed 15.0 m/s
        w.put(1, 2)                                            // driveDirection = backward
        w.constrained(120, 1, 1023); w.put(0, 3)               // length = 12.0 m
        w.constrained(25, 1, 62)                               // width = 2.5 m
        w.constrained(-15, -160, 161); w.put(1, 7)             // longAccel = -1.5 m/s²
        w.constrained(50, -1023, 1023); w.put(1, 3)            // curvature = 50 → radius 200 m
        w.put(0, 1); w.put(0, 2)                               // curvatureCalculationMode
        w.constrained(-1250, -32766, 32767); w.put(1, 4)       // yawRate = -12.50 °/s
        w.put(0b010_0010, 7)                                   // control: gasPedal + cruiseControl
        w.constrained(2, -1, 14)                               // lanePosition = 2
        w.constrained(-20, -511, 512); w.put(1, 7)             // steeringWheel = -30.0°
        w.constrained(-12, -160, 161); w.put(1, 7)             // latAccel = -1.2 m/s²
        w.constrained(3, -160, 161); w.put(1, 7)               // vertAccel = +0.3 m/s²
        w.put(4, 3)                                            // performanceClass = 4
        // LowFrequencyContainer: ext(1), role(4)=1 (publicTransport), lights(8), pathHistoryCount(6)=2
        w.put(0, 1); w.put(1, 4); w.put(0b1100_1000, 8)
        w.constrained(2, 0, 40)

        let s = CamParser.parse(w.finishWithBtp(), btpOff: 0)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.stationType, 6)
        XCTAssertEqual(s?.altitudeM ?? 0, 428.6, accuracy: 0.01)
        XCTAssertEqual(s?.headingDeg, 180.0)
        XCTAssertEqual(s?.speedMps, 15.0)
        XCTAssertEqual(s?.driveDirection, .backward)
        XCTAssertEqual(s?.lengthM, 12.0)
        XCTAssertEqual(s?.widthM, 2.5)
        XCTAssertEqual(s?.longAccel, -1.5)
        XCTAssertEqual(s?.curvature, 50)
        XCTAssertEqual(s?.curveRadiusM ?? 0, 200.0, accuracy: 0.01)
        XCTAssertEqual(s?.yawRateDegPerSec, -12.5)
        XCTAssertEqual(s?.control, [.gasPedal, .cruiseControl])
        XCTAssertEqual(s?.lanePosition, 2)
        XCTAssertEqual(s?.steeringWheelDeg, -30.0)
        XCTAssertEqual(s?.latAccel, -1.2)
        XCTAssertEqual(s?.vertAccel, 0.3)
        XCTAssertEqual(s?.performanceClass, 4)
        XCTAssertEqual(s?.vehicleRole, .publicTransport)
        XCTAssertEqual(s?.lights, [.lowBeam, .highBeam, .daytime])
        XCTAssertEqual(s?.pathHistoryCount, 2)
    }

    func testSpecialVehicleEmergencyContainerAfterPathHistory() {
        var w = BitWriter()
        w.put(2, 8); w.put(2, 8); w.put(0xAABB_CCDD, 32)
        w.put(0, 16)
        w.put(0, 1); w.put(1, 1); w.put(1, 1)                  // ext=0, LF=1, SV=1
        w.put(0, 1); w.put(10, 8); w.put(0, 123)               // BasicContainer: specialVehicle (10)
        w.put(0, 1); w.put(0, 1); w.put(0, 7)                  // HF basicVehicle, no optionals
        w.put(0, 12); w.put(1, 7); w.put(2000, 14); w.put(1, 7)
        w.put(0, 2)                                            // forward
        w.constrained(52, 1, 1023); w.put(0, 3)                // 5.2 m
        w.constrained(21, 1, 62)                               // 2.1 m
        w.constrained(0, -160, 161); w.put(1, 7)
        w.constrained(0, -1023, 1023); w.put(1, 3); w.put(0, 3)
        w.constrained(0, -32766, 32767); w.put(1, 4)
        // LF container: ext=0, role=6 (emergency), lights=lowBeam, 2 pathHistory points
        w.put(0, 1); w.put(6, 4); w.put(0b1000_0000, 8)
        w.constrained(2, 0, 40)
        // Point 1: hasDelta=1, deltaPos(51), PathDeltaTime ext=0 + 16 bits
        w.put(1, 1); w.put(0, 51); w.put(0, 1); w.put(50, 16)
        // Point 2: hasDelta=0, deltaPos(51)
        w.put(0, 1); w.put(0, 51)
        // SpecialVehicleContainer: ext=0, choice=5 (emergencyContainer), opt(2)=00, lightBarSirenInUse=11
        w.put(0, 1); w.constrained(5, 0, 6); w.put(0, 2); w.put(0b11, 2)

        let s = CamParser.parse(w.finishWithBtp(), btpOff: 0)
        XCTAssertEqual(s?.stationType, 10)
        XCTAssertEqual(s?.vehicleRole, .emergency)
        XCTAssertEqual(s?.pathHistoryCount, 2)
        XCTAssertEqual(s?.lightBar, true)
        XCTAssertEqual(s?.siren, true)
    }

    func testRsuCamBasicContainer() {
        var w = BitWriter()
        w.put(2, 8); w.put(2, 8); w.put(0x0000_0001, 32)
        w.put(0, 16)
        w.put(0, 1); w.put(0, 1); w.put(0, 1)
        w.put(0, 1); w.put(15, 8)                              // RSU
        w.constrained(480_000_000, -900_000_000, 900_000_001)
        w.constrained(90_000_000, -1_800_000_000, 1_800_000_001)
        w.put(0, 36)
        w.constrained(35_000, -100_000, 800_001)               // 350.0 m
        w.put(0, 4)
        w.put(0, 1); w.put(1, 1)                               // HF choice = 1 (rsuContainerHighFrequency)

        let s = CamParser.parse(w.finishWithBtp(), btpOff: 0)
        XCTAssertEqual(s?.stationType, 15)
        XCTAssertEqual(s?.altitudeM ?? 0, 350.0, accuracy: 0.01)
        XCTAssertNil(s?.speedMps)
    }
}
