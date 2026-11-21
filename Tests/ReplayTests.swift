import CoreLocation
import XCTest
@testable import V2X2

final class ReplayTests: XCTestCase {
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private func pcap(magic: UInt32, link: UInt32, le: Bool, records: [(UInt32, UInt32, [UInt8])]) -> Data {
        let u32: (UInt32) -> [UInt8] = le ? { self.le32($0) } : { self.be32($0) }
        var b = u32(magic)
        b += le ? [2, 0, 4, 0] : [0, 2, 0, 4]
        b += u32(0) + u32(0) + u32(65535) + u32(link)
        for (s, f, p) in records {
            b += u32(s) + u32(f) + u32(UInt32(p.count)) + u32(UInt32(p.count)) + p
        }
        return Data(b)
    }

    func testPcapLittleEndian80211AndTruncatedTail() throws {
        let p1: [UInt8] = [0x08, 0x00, 0x01, 0x02]
        let p2: [UInt8] = [0x08, 0x00, 0x03, 0x04, 0x05]
        var data = pcap(magic: 0xA1B2_C3D4, link: 105, le: true, records: [(1000, 250_000, p1), (1005, 500_000, p2)])
        // Append incomplete trailing record (should be ignored cleanly)
        data.append(contentsOf: le32(1010) + le32(0) + le32(50) + le32(50) + [0x01, 0x02])

        let frames = try PcapFile.parse(data)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload, p1)
        XCTAssertEqual(frames[0].received.timeIntervalSince1970, 1000.25, accuracy: 1e-6)
        XCTAssertEqual(frames[1].payload, p2)
        XCTAssertEqual(frames[1].received.timeIntervalSince1970, 1005.5, accuracy: 1e-6)
    }

    func testPcapBigEndianRadiotapNanoseconds() throws {
        // 8-byte radiotap header (ver 0, pad 0, len 8 LE) + 4-byte 802.11 payload
        let rt: [UInt8] = [0x00, 0x00, 0x08, 0x00, 0, 0, 0, 0] + [0x08, 0x00, 0xAA, 0xBB]
        let data = pcap(magic: 0xA1B2_3C4D, link: 127, le: false, records: [(2000, 500_000_000, rt)])

        let frames = try PcapFile.parse(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, [0x08, 0x00, 0xAA, 0xBB])
        XCTAssertEqual(frames[0].received.timeIntervalSince1970, 2000.5, accuracy: 1e-6)
    }

    func testPcapRejectsUnsupportedLinkOrInvalidHeader() {
        XCTAssertThrowsError(try PcapFile.parse(Data([1, 2, 3])))
        let eth = pcap(magic: 0xA1B2_C3D4, link: 1, le: true, records: [])
        XCTAssertThrowsError(try PcapFile.parse(eth))
    }

    func testTrackFileParseAndSort() {
        let csv = """
        time,lat,lon,speed_mps,course_deg
        1005.0,48.5001,9.2001,-1.0,-1.0
        1000.0,48.5000,9.2000,13.89,90.0
        """
        let fixes = TrackFile.parse(csv)
        XCTAssertEqual(fixes.count, 2)
        XCTAssertEqual(fixes[0].time.timeIntervalSince1970, 1000.0, accuracy: 1e-6)
        XCTAssertEqual(fixes[0].speedMps, 13.89)
        XCTAssertEqual(fixes[0].courseDeg, 90.0)
        XCTAssertNil(fixes[1].speedMps)
        XCTAssertNil(fixes[1].courseDeg)
    }

    func testReplayerSeekAndClock() {
        defer { Clock.replayTime = nil }
        let frames = [0, 30, 100, 110].enumerated().map { idx, offset in
            Frame(id: idx + 1, received: Date(timeIntervalSince1970: 1000 + Double(offset)),
                  sec: UInt32(1000 + offset), usec: 0, payload: [UInt8(idx)], decoded: ItsG5Decoder.Decoded())
        }
        let track = [
            Recording.Fix(time: Date(timeIntervalSince1970: 1000), coordinate: .init(latitude: 48.5, longitude: 9.2), speedMps: 10, courseDeg: 0),
            Recording.Fix(time: Date(timeIntervalSince1970: 1105), coordinate: .init(latitude: 48.51, longitude: 9.21), speedMps: 15, courseDeg: 45),
        ]
        let r = Recording(frames: frames, track: track)
        let replayer = Replayer()
        var delivered: [(Int, Bool)] = []
        var resets = 0
        replayer.lookback = { 50 }
        replayer.onFrame = { f, quiet in delivered.append((f.id, quiet)) }
        replayer.onReset = { resets += 1; delivered.removeAll() }

        replayer.begin(r, name: "test", autoplay: false)
        XCTAssertEqual(delivered.map(\.0), [1])
        XCTAssertEqual(replayer.trackIndex, 0)
        XCTAssertEqual(Clock.now.timeIntervalSince1970, 1000, accuracy: 1e-6)

        // Seek to t+110 with lookback 50s -> should replay frames in [t+60, t+110], i.e. ids 3 and 4, quietly
        replayer.seek(toElapsed: 110)
        XCTAssertEqual(resets, 2)
        XCTAssertEqual(delivered.map(\.0), [3, 4])
        XCTAssertTrue(delivered.allSatisfy(\.1))
        XCTAssertEqual(replayer.trackIndex, 1)
        XCTAssertEqual(replayer.playedTrack.count, 2)
        XCTAssertEqual(Clock.now.timeIntervalSince1970, 1110, accuracy: 1e-6)

        replayer.stop()
        XCTAssertFalse(replayer.isActive)
        XCTAssertNil(Clock.replayTime)
    }
}
