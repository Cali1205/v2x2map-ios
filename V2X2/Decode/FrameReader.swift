import Foundation

/// One sniffed 802.11 frame from the ESP32-C5 plus what the decoder could extract.
struct Frame: Identifiable {
    let id: Int
    let received: Date
    let sec: UInt32
    let usec: UInt32
    let payload: [UInt8]
    let decoded: ItsG5Decoder.Decoded

    /// 802.11 transmitter address (addr2) — groups frames without a GeoNetworking station id.
    var transmitter: UInt64? {
        guard payload.count >= 16 else { return nil }
        return payload[10..<16].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func hexPreview(_ maxBytes: Int = 32) -> String {
        payload.prefix(maxBytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Resync parser for the ESP wire format (same as android FrameReader.kt):
///   "ITS5" | sec u32 LE | usec u32 LE | len u16 LE | payload[len]
/// BLE notifications split frames at MTU boundaries, so bytes are buffered until complete.
struct FrameReader {
    static let headerLen = 14
    static let maxPayload = 4096
    private static let magic: [UInt8] = [0x49, 0x54, 0x53, 0x35]

    private var buf: [UInt8] = []
    private var seq = 0

    mutating func feed(_ chunk: Data) -> [Frame] {
        buf.append(contentsOf: chunk)
        var out: [Frame] = []
        while true {
            guard let m = magicIndex() else {
                if buf.count > 3 { buf.removeFirst(buf.count - 3) } // magic may span chunks
                return out
            }
            buf.removeFirst(m)
            guard buf.count >= Self.headerLen else { return out }
            let len = Int(buf[12]) | Int(buf[13]) << 8
            if len > Self.maxPayload { buf.removeFirst(4); continue } // implausible → resync
            guard buf.count >= Self.headerLen + len else { return out }
            let payload = Array(buf[Self.headerLen ..< Self.headerLen + len])
            let sec = le32(4), usec = le32(8)
            buf.removeFirst(Self.headerLen + len)
            seq += 1
            out.append(Frame(id: seq, received: Date(), sec: sec, usec: usec,
                             payload: payload, decoded: ItsG5Decoder.decode(payload)))
        }
    }

    private func le32(_ o: Int) -> UInt32 {
        UInt32(buf[o]) | UInt32(buf[o + 1]) << 8 | UInt32(buf[o + 2]) << 16 | UInt32(buf[o + 3]) << 24
    }

    private func magicIndex() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 0x49 && buf[i + 1] == 0x54 && buf[i + 2] == 0x53 && buf[i + 3] == 0x35 {
            return i
        }
        return nil
    }
}
