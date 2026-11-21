import CoreLocation
import Foundation
import Observation

/// Own position + kinematics at a given timestamp (live GPS or interpolated replay track).
struct OwnFix {
    let time: Date
    let coordinate: CLLocationCoordinate2D
    let speedMps: Double?
    let courseDeg: Double?
    let accuracyM: Double?

    /// Projects `coordinate` forward up to `maxSeconds` when moving, to compensate for 0–2 s GPS lag vs. CAMs.
    func projected(to target: Date, maxSeconds: TimeInterval = 2.5) -> OwnFix {
        let dt = target.timeIntervalSince(time)
        guard dt > 0, dt <= maxSeconds, let speed = speedMps, speed >= 1.0, let course = courseDeg else { return self }
        return OwnFix(time: target, coordinate: Self.offset(coordinate, meters: speed * dt, bearingDeg: course),
                      speedMps: speed, courseDeg: course, accuracyM: accuracyM)
    }

    static func offset(_ c: CLLocationCoordinate2D, meters: Double, bearingDeg: Double) -> CLLocationCoordinate2D {
        let r = 6_371_000.0
        let d = meters / r
        let brng = bearingDeg * .pi / 180
        let lat1 = c.latitude * .pi / 180
        let lon1 = c.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}

/// Identifies the user's own vehicle among received CAM stations by correlating position, speed and
/// heading with the phone's GPS over time, and transfers identity seamlessly across ITS-G5 pseudonym changes.
@Observable
final class EgoDetector {
    struct Candidate {
        let id: UInt64
        var score: Double = 0
        var matches: Int = 0
        var misses: Int = 0
        var firstMatch: Date?
        var lastSeen: Date
        var coordinate: CLLocationCoordinate2D
        var speedMps: Double?
        var headingDeg: Double?
        var handoffFrom: UInt64?
        var handoffAt: Date?
    }

    private(set) var egoId: UInt64?
    private(set) var pastEgoIds: Set<UInt64> = []
    private(set) var pseudonymSwitches = 0

    @ObservationIgnored private var candidates: [UInt64: Candidate] = [:]

    func isOwnVehicle(_ id: UInt64) -> Bool {
        id == egoId || pastEgoIds.contains(id)
    }

    func isSupersededOwnVehicle(_ id: UInt64) -> Bool {
        pastEgoIds.contains(id) && id != egoId
    }

    func reset() {
        egoId = nil
        pastEgoIds.removeAll()
        pseudonymSwitches = 0
        candidates.removeAll()
    }

    func observe(frame: Frame, stationId: UInt64, own: OwnFix?) {
        let d = frame.decoded
        guard d.msgType == .cam, d.stationType != 15,
              let lat = d.latitude, let lon = d.longitude else { return }

        let now = frame.received
        let camCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let camSpeed = d.speedMps.flatMap { $0 >= 0 && $0 < 90 ? $0 : nil }
        let camHeading = d.headingDeg

        var cand = candidates[stationId] ?? Candidate(id: stationId, lastSeen: now, coordinate: camCoord)
        let isBrandNew = candidates[stationId] == nil
        let dt = max(0, now.timeIntervalSince(cand.lastSeen))
        cand.score *= exp(-dt / 25.0)
        cand.lastSeen = now
        cand.coordinate = camCoord
        cand.speedMps = camSpeed
        cand.headingDeg = camHeading

        // Check for a pseudonym handoff when a brand-new station appears right where the current ego was.
        if isBrandNew, let curId = egoId, curId != stationId, !pastEgoIds.contains(stationId),
           let prev = candidates[curId],
           matchesHandoff(prev: prev, nextCoord: camCoord, nextSpeed: camSpeed, nextHeading: camHeading, now: now, own: own) {
            cand.handoffFrom = curId
            cand.handoffAt = now
        }

        // Cancel a pending handoff if the previous ego ID keeps transmitting afterwards.
        if let curId = egoId, stationId == curId {
            for (k, v) in candidates where v.handoffFrom == curId && now.timeIntervalSince(v.handoffAt ?? now) > 0.5 {
                candidates[k]?.handoffFrom = nil
                candidates[k]?.handoffAt = nil
            }
        }

        // Score against own GPS trajectory.
        if let own {
            let fixAge = max(0, now.timeIntervalSince(own.time))
            let dist = Self.meters(camCoord, own.coordinate)
            let moving = (own.speedMps ?? 0) >= 2.0 && fixAge <= 6.0
            let radius = 35.0 + min(20.0, own.accuracyM ?? 10.0)

            var speedOk = true
            var speedBad = false
            if let vCam = camSpeed, let vOwn = own.speedMps, vOwn >= 0, fixAge <= 6.0 {
                let dv = abs(vCam - vOwn)
                speedOk = dv <= max(3.0, 0.22 * max(vCam, vOwn))
                speedBad = dv > max(7.0, 0.45 * max(vCam, vOwn))
            }

            var headingOk = true
            var headingBad = false
            if moving, let hCam = camHeading, let hOwn = own.courseDeg, (camSpeed ?? 0) >= 2.0 {
                let dh = Self.angleDiff(hCam, hOwn)
                headingOk = dh <= 28.0
                headingBad = dh > 60.0
            }

            if dist <= radius && !speedBad && !headingBad {
                cand.matches += 1
                cand.misses = 0
                if cand.firstMatch == nil { cand.firstMatch = now }

                let posGain = max(0.1, 1.0 - dist / (radius + 10.0))
                let kinGain = (moving && speedOk && headingOk) ? 0.6 : 0.0
                if moving {
                    cand.score = min(30.0, cand.score + posGain + kinGain)
                } else if stationId == egoId {
                    // Keep an already-confirmed ego vehicle locked while stopped (e.g. at a traffic light).
                    cand.score = min(30.0, cand.score + 0.3)
                } else {
                    // Don't confirm a brand-new stationary neighbour at a traffic light without movement.
                    cand.score = min(3.5, cand.score + 0.2)
                }
            } else {
                cand.misses += 1
                let penalty = (headingBad || dist > 120.0) ? 4.0 : 2.0
                cand.score = max(-5.0, cand.score - penalty)
                if stationId == egoId && (cand.misses >= 4 || cand.score < 1.0 || dist > 150.0) {
                    egoId = nil
                }
            }
        }

        candidates[stationId] = cand

        // Complete a pending pseudonym handoff once the old ID has stayed silent for >= 1.2 s and the new ID looks solid.
        if let fromId = cand.handoffFrom, let prev = candidates[fromId],
           fromId == egoId, cand.matches >= 2, cand.misses == 0,
           now.timeIntervalSince(prev.lastSeen) >= 1.2 {
            pastEgoIds.insert(fromId)
            egoId = stationId
            cand.score = max(cand.score, 10.0)
            cand.handoffFrom = nil
            cand.handoffAt = nil
            candidates[stationId] = cand
            pseudonymSwitches += 1
            return
        }

        evaluateCandidates(now: now)
    }

    func prune(now: Date) {
        if let cur = egoId, let c = candidates[cur], now.timeIntervalSince(c.lastSeen) > 20 {
            if c.score >= 6.0 { pastEgoIds.insert(cur) }
            egoId = nil
        }
        candidates = candidates.filter { now.timeIntervalSince($0.value.lastSeen) <= 30 }
    }

    private func evaluateCandidates(now: Date) {
        let active = candidates.values
            .filter { now.timeIntervalSince($0.lastSeen) <= 5.0 && !pastEgoIds.contains($0.id) }
            .sorted { $0.score > $1.score }
        guard let best = active.first else { return }
        let second = active.dropFirst().first

        if egoId == nil {
            let span = best.lastSeen.timeIntervalSince(best.firstMatch ?? best.lastSeen)
            let marginOk = second == nil || best.score >= second!.score + 2.0
            if best.score >= 5.0 && best.matches >= 5 && span >= 3.0 && marginOk {
                egoId = best.id
            }
        } else if let curId = egoId, best.id != curId, let cur = candidates[curId] {
            if best.score >= 8.0 && best.matches >= 8 && best.score >= cur.score + 5.0 {
                egoId = best.id
            }
        }
    }

    private func matchesHandoff(prev: Candidate, nextCoord: CLLocationCoordinate2D, nextSpeed: Double?,
                                nextHeading: Double?, now: Date, own: OwnFix?) -> Bool {
        let gap = now.timeIntervalSince(prev.lastSeen)
        guard gap >= 0, gap <= 10.0 else { return false }

        let expected: CLLocationCoordinate2D
        if let s = prev.speedMps, s >= 1.0, let h = prev.headingDeg {
            expected = OwnFix.offset(prev.coordinate, meters: s * gap, bearingDeg: h)
        } else {
            expected = prev.coordinate
        }
        guard Self.meters(expected, nextCoord) <= 35.0 else { return false }

        if let own, abs(now.timeIntervalSince(own.time)) <= 6.0, Self.meters(nextCoord, own.coordinate) > 50.0 {
            return false
        }
        if let s1 = prev.speedMps, let s2 = nextSpeed, abs(s1 - s2) > max(3.0, 0.25 * max(s1, s2)) { return false }
        if let h1 = prev.headingDeg, let h2 = nextHeading, (prev.speedMps ?? 0) >= 2.0, Self.angleDiff(h1, h2) > 28.0 {
            return false
        }
        return true
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        return d > 180.0 ? 360.0 - d : d
    }
}
