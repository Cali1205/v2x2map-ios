import Foundation
import Observation

/// Writes received frames to a standard .pcap (link type 105 = IEEE 802.11) for Wireshark.
/// Files land in the app's Documents folder (visible in the Files app).
@Observable
final class PcapRecorder {
    private(set) var currentFile: URL?
    private(set) var lastFile: URL?
    private(set) var frames = 0
    @ObservationIgnored private var handle: FileHandle?

    var isRecording: Bool { handle != nil }

    func start() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = docs.appendingPathComponent("v2x2-\(f.string(from: Date())).pcap")
        var hdr = Data()
        hdr.le32(0xA1B2_C3D4); hdr.le16(2); hdr.le16(4); hdr.le32(0); hdr.le32(0); hdr.le32(65535); hdr.le32(105)
        guard FileManager.default.createFile(atPath: url.path, contents: hdr),
              let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        handle = h
        currentFile = url
        frames = 0
    }

    func stop() {
        try? handle?.close()
        handle = nil
        lastFile = currentFile
        currentFile = nil
    }

    func write(_ frame: Frame) {
        guard let h = handle else { return }
        // ESP clock is not wall time; use the phone's receive time so captures line up with GPS.
        let t = frame.received.timeIntervalSince1970
        var rec = Data()
        rec.le32(UInt32(t)); rec.le32(UInt32((t - floor(t)) * 1_000_000))
        rec.le32(UInt32(frame.payload.count)); rec.le32(UInt32(frame.payload.count))
        rec.append(contentsOf: frame.payload)
        h.write(rec)
        frames += 1
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
