import CoreLocation
import Foundation
import MapKit
import Observation

/// Time base for "still sending" and marker expiry: wall time live, the recording's time during a replay.
enum Clock {
    static var replayTime: Date?
    static var now: Date { replayTime ?? Date() }
}

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
    var trackURL: URL { url.deletingPathExtension().appendingPathExtension("csv") }
    var hasTrack: Bool { FileManager.default.fileExists(atPath: trackURL.path) }

    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func all() -> [RecordingFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return urls.filter { $0.pathExtension.lowercased() == "pcap" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let name = u.deletingPathExtension().lastPathComponent
            return RecordingFile(url: u, started: f.date(from: String(name.dropFirst("v2x2-".count))),
                                 modified: v?.contentModificationDate, size: v?.fileSize ?? 0)
        }
        .sorted { ($0.started ?? $0.modified ?? .distantPast) > ($1.started ?? $1.modified ?? .distantPast) }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: trackURL)
    }
}

/// Plays a recording back through the normal station pipeline, with its own clock (`Clock.replayTime`)
/// so "active", greying out and marker expiry behave like they did during the drive.
@Observable
final class Replayer {
    static let speeds: [Double] = [1, 2, 4, 8, 16, 32]

    private(set) var recording: Recording?
    private(set) var name: String?
    private(set) var position: Date?
    private(set) var isPlaying = false
    private(set) var loading = false
    private(set) var trackIndex = -1
    var error: String?
    var speed: Double = 4

    /// Delivers a frame to the station model; `quiet` while rebuilding the state after a seek.
    @ObservationIgnored var onFrame: ((Frame, _ quiet: Bool) -> Void)?
    /// Clears the station model (start, seek, stop).
    @ObservationIgnored var onReset: (() -> Void)?
    /// How far back a seek replays frames to rebuild the map (the marker lifetime).
    @ObservationIgnored var lookback: () -> TimeInterval = { 600 }

    @ObservationIgnored private var nextFrame = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()

    /// Gaps without frames or GPS fixes longer than this (recording time) are skipped.
    static let maxGap: TimeInterval = 20

    var isActive: Bool { recording != nil }
    var start: Date? { recording?.start }
    var duration: TimeInterval { recording.flatMap { r in r.end.flatMap { e in r.start.map { e.timeIntervalSince($0) } } } ?? 0 }
    var elapsed: TimeInterval { position.flatMap { p in start.map { p.timeIntervalSince($0) } } ?? 0 }
    var hasTrack: Bool { !(recording?.track.isEmpty ?? true) }
    var fix: Recording.Fix? { trackIndex >= 0 ? recording?.track[trackIndex] : nil }
    var fullTrack: [CLLocationCoordinate2D] { recording?.track.map(\.coordinate) ?? [] }
    var playedTrack: [CLLocationCoordinate2D] {
        guard let t = recording?.track, trackIndex >= 0 else { return [] }
        return t[...trackIndex].map(\.coordinate)
    }

    func load(_ url: URL) {
        stop()
        loading = true
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> Recording in
                let frames = try PcapFile.parse(Data(contentsOf: url, options: .mappedIfSafe))
                let csv = url.deletingPathExtension().appendingPathExtension("csv")
                let track = (try? String(contentsOf: csv, encoding: .utf8)).map(TrackFile.parse) ?? []
                return Recording(frames: frames, track: track)
            }
            await MainActor.run {
                self.loading = false
                switch result {
                case .failure(let e): self.error = e.localizedDescription
                case .success(let r) where r.frames.isEmpty && r.track.isEmpty: self.error = "Die Aufnahme ist leer."
                case .success(let r): self.begin(r, name: url.deletingPathExtension().lastPathComponent)
                }
            }
        }
    }

    func begin(_ r: Recording, name: String, autoplay: Bool = true) {
        recording = r
        self.name = name
        seek(toElapsed: 0)
        if autoplay { play() }
    }

    func play() {
        guard isActive else { return }
        if elapsed >= duration { seek(toElapsed: 0) }
        isPlaying = true
        lastTick = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        recording = nil
        name = nil
        position = nil
        trackIndex = -1
        nextFrame = 0
        Clock.replayTime = nil
        onReset?()
    }

    func skip(_ seconds: TimeInterval) { seek(toElapsed: elapsed + seconds) }

    /// Rebuilds the map for the given point in time: clears it, then quietly replays the frames
    /// of the last marker lifetime before it.
    func seek(toElapsed e: TimeInterval) {
        guard let r = recording, let s = r.start else { return }
        let t = s.addingTimeInterval(min(max(0, e), duration))
        onReset?()
        let from = t.addingTimeInterval(-lookback())
        nextFrame = r.frames.firstIndex { $0.received >= from } ?? r.frames.count
        trackIndex = -1
        advance(to: t, quiet: true)
    }

    private func tick() {
        guard let r = recording, let p = position, let end = r.end else { return }
        let now = Date()
        var t = p.addingTimeInterval(now.timeIntervalSince(lastTick) * speed)
        lastTick = now
        // Don't sit through long pauses (receiver out of range, parked) at normal speed.
        let nextEvent = [nextFrame < r.frames.count ? r.frames[nextFrame].received : nil,
                         trackIndex + 1 < r.track.count ? r.track[trackIndex + 1].time : nil].compactMap { $0 }.min()
        if let n = nextEvent, n.timeIntervalSince(t) > Self.maxGap { t = n.addingTimeInterval(-1) }
        if t >= end {
            advance(to: end)
            pause()
        } else {
            advance(to: t)
        }
    }

    /// Feeds every frame and GPS fix up to `t`.
    func advance(to t: Date, quiet: Bool = false) {
        guard let r = recording else { return }
        Clock.replayTime = t
        position = t
        while nextFrame < r.frames.count, r.frames[nextFrame].received <= t {
            onFrame?(r.frames[nextFrame], quiet)
            nextFrame += 1
        }
        var i = trackIndex
        while i + 1 < r.track.count, r.track[i + 1].time <= t { i += 1 }
        if i != trackIndex { trackIndex = i }
    }
}
