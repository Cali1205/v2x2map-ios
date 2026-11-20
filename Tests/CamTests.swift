import XCTest
@testable import V2X2

final class CamTests: XCTestCase {
    /// Builds an ITS PDU (from the BTP header) for a CAM with the given HF/LF values, bit by bit.
    private func cam(speed: Int, heading: Int, accel: Int, control: Int?, lights: Int?) -> [UInt8] {
        var bits = ""
        func put(_ v: Int, _ n: Int) { bits += String(String(v, radix: 2).suffix(n)).leftPad(n) }
        put(2, 8); put(2, 8); put(0x1234_5678, 32)            // ItsPduHeader
        put(0, 16)                                            // generationDeltaTime
        put(0, 1); put(lights == nil ? 0 : 1, 1); put(0, 1)  // ext, LF, special
        put(0, 1); put(5, 8); put(0, 123)                     // basic container
        put(0, 1); put(0, 1)                                  // HF choice basicVehicle
        put(control == nil ? 0 : 1, 1); put(0, 6)             // optionals
        put(heading, 12); put(1, 7); put(speed, 14); put(1, 7)
        put(0, 2); put(45, 13); put(18, 6)
        put(accel + 160, 9); put(1, 7)
        put(0, 14); put(0, 3); put(0, 20)
        if let c = control { put(c, 7) }
        if let l = lights { put(0, 1); put(0, 4); put(l, 8) }
        while bits.count % 8 != 0 { bits += "0" }
        let body = stride(from: 0, to: bits.count, by: 8).map { i -> UInt8 in
            let s = bits.index(bits.startIndex, offsetBy: i)
            return UInt8(bits[s..<bits.index(s, offsetBy: 8)], radix: 2)!
        }
        return [0x07, 0xD1, 0, 0] + body
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
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}
