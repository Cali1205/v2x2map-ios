import CoreLocation
import Foundation
import Observation

/// Time base for "still sending" and marker expiry: wall time live, the recording's time during a replay.
enum Clock {
    static var replayTime: Date?
    static var now: Date { replayTime ?? Date() }
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
    var fix: Recording.Fix? { trackIndex >= 0 ? recording?.track[trackIndex] : nil }
    var playedTrack: [CLLocationCoordinate2D] {
        guard let t = recording?.track, trackIndex >= 0 else { return [] }
        return t[...trackIndex].map(\.coordinate)
    }
    var remainingTrack: [CLLocationCoordinate2D] {
        guard let t = recording?.track else { return [] }
        let start = max(0, trackIndex)
        guard start < t.count else { return [] }
        return t[start...].map(\.coordinate)
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
                let csv = RecordingFile.trackURL(for: url)
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

    /// Interpolated recorded position at `time` (O(log n) lookup for fast seek rebuilds).
    func ownFix(at time: Date) -> OwnFix? {
        guard let t = recording?.track, !t.isEmpty else { return nil }
        var lo = 0, hi = t.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if t[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        let prevIdx = lo - 1
        let nextIdx = lo < t.count ? lo : nil

        if prevIdx >= 0, let ni = nextIdx {
            let a = t[prevIdx], b = t[ni]
            let span = b.time.timeIntervalSince(a.time)
            if span > 0, span <= 15 {
                let u = time.timeIntervalSince(a.time) / span
                let coord = CLLocationCoordinate2D(
                    latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * u,
                    longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * u
                )
                let speed = a.speedMps.flatMap { s1 in b.speedMps.map { s1 + ($0 - s1) * u } } ?? a.speedMps
                let course: Double?
                if let c1 = a.courseDeg, let c2 = b.courseDeg {
                    var delta = (c2 - c1).truncatingRemainder(dividingBy: 360.0)
                    if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                    course = (c1 + delta * u + 360).truncatingRemainder(dividingBy: 360.0)
                } else {
                    course = a.courseDeg ?? b.courseDeg
                }
                return OwnFix(time: time, coordinate: coord, speedMps: speed, courseDeg: course, accuracyM: nil)
            }
        }
        if prevIdx >= 0 {
            let a = t[prevIdx]
            return OwnFix(time: a.time, coordinate: a.coordinate, speedMps: a.speedMps, courseDeg: a.courseDeg, accuracyM: nil)
                .projected(to: time)
        }
        if let ni = nextIdx {
            let b = t[ni]
            if b.time.timeIntervalSince(time) <= 5 {
                return OwnFix(time: b.time, coordinate: b.coordinate, speedMps: b.speedMps, courseDeg: b.courseDeg, accuracyM: nil)
            }
        }
        return nil
    }
}
