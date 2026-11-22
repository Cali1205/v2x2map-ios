import CoreLocation
import Foundation
import MapKit

/// A recorded drive: the frames from the .pcap and, if it was recorded alongside, the own GPS track (.csv).
struct Recording {
    struct Fix {
        let time: Date
        let coordinate: CLLocationCoordinate2D
        let speedMps: Double?
        let courseDeg: Double?
    }

    var frames: [Frame]
    var track: [Fix] = []

    var start: Date? { [frames.first?.received, track.first?.time].compactMap { $0 }.min() }
    var end: Date? { [frames.last?.received, track.last?.time].compactMap { $0 }.max() }

    /// Region covering the own track and every decoded station position.
    var region: MKCoordinateRegion? {
        let stationPts = frames.compactMap { f -> CLLocationCoordinate2D? in
            guard let lat = f.decoded.latitude, let lon = f.decoded.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let pts = track.map(\.coordinate) + stationPts
        guard let first = pts.first else { return nil }
        var (minLat, maxLat, minLon, maxLon) = (first.latitude, first.latitude, first.longitude, first.longitude)
        for p in pts {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        return MKCoordinateRegion(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: .init(latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                                              longitudeDelta: max(0.01, (maxLon - minLon) * 1.3)))
    }
}

/// Reads classic libpcap files: as written by `PcapRecorder` (link type 105, raw 802.11) and Wireshark
/// captures with radiotap headers (127). Either byte order, µs or ns timestamps.
enum PcapFile {
    enum ParseError: LocalizedError {
        case notPcap, unsupportedLinkType(UInt32)
        var errorDescription: String? {
            switch self {
            case .notPcap: "Keine PCAP-Datei (pcapng wird nicht unterstützt)."
            case .unsupportedLinkType(let t): "PCAP-Linktyp \(t) wird nicht unterstützt (nur 802.11 und Radiotap)."
            }
        }
    }

    static func parse(_ data: Data) throws -> [Frame] {
        let b = [UInt8](data)
        guard b.count >= 24 else { throw ParseError.notPcap }
        let le: Bool, nano: Bool
        switch u32(b, 0, le: true) {
        case 0xA1B2_C3D4: (le, nano) = (true, false)
        case 0xA1B2_3C4D: (le, nano) = (true, true)
        case 0xD4C3_B2A1: (le, nano) = (false, false)
        case 0x4D3C_B2A1: (le, nano) = (false, true)
        default: throw ParseError.notPcap
        }
        let link = u32(b, 20, le: le)
        guard link == 105 || link == 127 else { throw ParseError.unsupportedLinkType(link) }

        var out: [Frame] = []
        var o = 24
        while o + 16 <= b.count {
            let sec = u32(b, o, le: le), frac = u32(b, o + 4, le: le), len = Int(u32(b, o + 8, le: le))
            o += 16
            guard len <= b.count - o else { break }  // last record cut off (app killed while recording)
            var p = Array(b[o ..< o + len])
            o += len
            if link == 127 {  // radiotap: u8 version, u8 pad, u16 LE header length
                guard p.count >= 4 else { continue }
                let h = Int(p[2]) | Int(p[3]) << 8
                guard h <= p.count else { continue }
                p.removeFirst(h)
            }
            let usec = nano ? frac / 1000 : frac
            out.append(Frame(id: out.count + 1, received: Date(timeIntervalSince1970: Double(sec) + Double(usec) / 1e6),
                             sec: sec, usec: usec, payload: p, decoded: ItsG5Decoder.decode(p)))
        }
        return out
    }

    private static func u32(_ b: [UInt8], _ o: Int, le: Bool) -> UInt32 {
        let v = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        return le ? v : v.byteSwapped
    }
}

/// GPS track written next to a recording: `time,lat,lon,speed_mps,course_deg`, negative = unknown.
enum TrackFile {
    static let header = "time,lat,lon,speed_mps,course_deg\n"

    static func line(_ l: CLLocation) -> String {
        String(format: "%.3f,%.7f,%.7f,%.2f,%.1f\n", l.timestamp.timeIntervalSince1970,
               l.coordinate.latitude, l.coordinate.longitude, l.speed, l.course)
    }

    static func parse(_ text: String) -> [Recording.Fix] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let v = line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count >= 3, let t = v[0], let lat = v[1], let lon = v[2] else { return nil }  // also skips the header
            let speed = v.count > 3 ? v[3].flatMap { $0 >= 0 ? $0 : nil } : nil
            let course = v.count > 4 ? v[4].flatMap { $0 >= 0 ? $0 : nil } : nil
            return .init(time: Date(timeIntervalSince1970: t), coordinate: .init(latitude: lat, longitude: lon),
                         speedMps: speed, courseDeg: course)
        }
        .sorted { $0.time < $1.time }
    }
}

/// A recording file in the app's Documents folder.
struct RecordingFile: Identifiable {
    let url: URL
    let started: Date?
    let modified: Date?
    let size: Int
    var id: URL { url }
    var trackURL: URL { Self.trackURL(for: url) }
    var hasTrack: Bool { FileManager.default.fileExists(atPath: trackURL.path) }

    static let filePrefix = "v2x2-"
    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    static func trackURL(for pcapURL: URL) -> URL {
        pcapURL.deletingPathExtension().appendingPathExtension("csv")
    }

    static func all() -> [RecordingFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let f = makeDateFormatter()
        return urls.filter { $0.pathExtension.lowercased() == "pcap" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let name = u.deletingPathExtension().lastPathComponent
            return RecordingFile(url: u, started: f.date(from: String(name.dropFirst(filePrefix.count))),
                                 modified: v?.contentModificationDate, size: v?.fileSize ?? 0)
        }
        .sorted { ($0.started ?? $0.modified ?? .distantPast) > ($1.started ?? $1.modified ?? .distantPast) }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: trackURL)
    }
}
