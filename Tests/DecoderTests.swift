import XCTest
@testable import V2X2

final class DecoderTests: XCTestCase {
    private func be32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }

    /// Unsecured CAM: 802.11 data hdr | SNAP 0x8947 | GN basic | GN common (SHB) | LPV | BTP-B 2001.
    private func camFrame(lat: Double, lon: Double, speedCms: Int, headingDeci: Int) -> [UInt8] {
        var p: [UInt8] = [0x08, 0x00, 0x00, 0x00] + Array(repeating: 0xFF, count: 6)
            + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55] + Array(repeating: 0xFF, count: 6) + [0x00, 0x00]
        p += [0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47]
        p += [0x11, 0x00, 0x1A, 0x01]                              // basic: NH=1
        p += [0x20, 0x50, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00]      // common: BTP-B, HT=5 HST=0
        p += [5 << 2, 0x00, 0x02, 0x11, 0x22, 0x33, 0x44, 0x55]    // GN addr, stationType 5
        p += [0, 0, 0, 0]                                          // timestamp
        p += be32(Int32(lat * 1e7)) + be32(Int32(lon * 1e7))
        p += be32(Int32(bitPattern: UInt32(speedCms) << 16 | UInt32(headingDeci)))
        p += [0, 0, 0, 0]                                          // SHB reserved
        p += [0x07, 0xD1, 0x00, 0x00]                              // BTP-B dst 2001
        p += [0x02, 0x02, 0x00, 0x00, 0x00, 0x01]                  // ITS PDU header stub
        return p
    }

    private func wire(_ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        return Array("ITS5".utf8) + [1, 0, 0, 0, 2, 0, 0, 0, UInt8(n & 0xFF), UInt8(n >> 8)] + payload
    }

    func testCamDecodes() {
        let d = ItsG5Decoder.decode(camFrame(lat: 48.1234567, lon: 11.5, speedCms: 1389, headingDeci: 900))
        XCTAssertEqual(d.etherType, 0x8947)
        XCTAssertEqual(d.msgType, .cam)
        XCTAssertEqual(d.stationType, 5)
        XCTAssertEqual(d.secured, false)
        XCTAssertEqual(d.latitude!, 48.1234567, accuracy: 1e-6)
        XCTAssertEqual(d.longitude!, 11.5, accuracy: 1e-6)
        XCTAssertEqual(d.speedMps!, 13.89, accuracy: 1e-9)
        XCTAssertEqual(d.headingDeg!, 90, accuracy: 1e-9)
        XCTAssertEqual(d.stationId, 0x1400_0211_2233_4455)
    }

    func testTruncatedFramesNeverCrash() {
        let full = camFrame(lat: 48, lon: 11, speedCms: 0, headingDeci: 0)
        for n in 0..<full.count { _ = ItsG5Decoder.decode(Array(full.prefix(n))) }
    }

    func testReaderResyncsAcrossChunks() {
        let f = camFrame(lat: 52.5, lon: 13.4, speedCms: 500, headingDeci: 1800)
        let bytes: [UInt8] = Array("boot noise ITS".utf8) + wire(f) + wire(f)
        var reader = FrameReader()
        var frames: [Frame] = []
        var i = 0
        while i < bytes.count {               // BLE-sized chunks split frames anywhere
            let j = min(i + 20, bytes.count)
            frames += reader.feed(Data(bytes[i..<j]))
            i = j
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.payload, f)
        XCTAssertEqual(frames.first?.sec, 1)
        XCTAssertEqual(frames.first?.usec, 2)
        XCTAssertEqual(frames.first?.decoded.msgType, .cam)
        XCTAssertEqual(frames.first?.transmitter, 0x0211_2233_4455)
    }
}

final class DenmTests: XCTestCase {
    /// Real DENM (BTP-B header onwards) received 2026-11-20: passenger car, causeCode 1 (traffic condition).
    func testRealDenmCauseAndEventPosition() {
        let hex = "07d2000002019674a359c74b3a51acc57595056b0d7525415ac35f7528bf97770c6c92c11c11836c22e0c88800f014100803000058f07e81300483ef"
        let p = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        }
        XCTAssertEqual(DenmParser.extractCause(p, btpOff: 0), DenmParser.Cause(causeCode: 1, subCauseCode: 0))

        let info = DenmParser.parse(p, btpOff: 0)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.cause, DenmParser.Cause(causeCode: 1, subCauseCode: 0))
        XCTAssertEqual(info?.stationType, 5)
        XCTAssertEqual(info?.latitude ?? 0, 48.4905079, accuracy: 1e-6)
        XCTAssertEqual(info?.longitude ?? 0, 9.2075820, accuracy: 1e-6)
        XCTAssertEqual(info?.altitudeM ?? 0, 428.60, accuracy: 0.01)
    }

    func testMsgTypesAndStationClasses() {
        XCTAssertEqual(MsgType(btpPort: 2009), .cpm)
        XCTAssertGreaterThan(MsgType.spatem.displayPriority, MsgType.mapem.displayPriority)
        XCTAssertGreaterThan(MsgType.denm.displayPriority, MsgType.cam.displayPriority)
        XCTAssertEqual(StationClass.label(for: 5), "PKW")
        XCTAssertEqual(StationClass.label(for: 15), "RSU (Infrastruktur)")
        XCTAssertEqual(StationClass.symbol(for: 15), "antenna.radiowaves.left.and.right")
        XCTAssertEqual(StationClass.symbol(for: 6), "bus.fill")
    }
}
