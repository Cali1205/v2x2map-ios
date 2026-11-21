import Foundation

/// Big-endian bit reader for UPER. Reads past the end yield 0 (like the Kotlin version).
struct BitReader {
    let b: [UInt8]
    var pos: Int

    init(_ b: [UInt8], startByte: Int) { self.b = b; pos = startByte * 8 }

    @discardableResult
    mutating func bit() -> Int {
        guard pos / 8 < b.count else { return 0 }
        defer { pos += 1 }
        return Int(b[pos / 8] >> (7 - UInt8(pos % 8))) & 1
    }

    /// Reads up to 62 bits as a value; longer fields are skipped with `skip`.
    mutating func bits(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<max(n, 0) { v = (v << 1) | bit() }
        return v
    }

    mutating func skip(_ n: Int) { pos += max(n, 0) }

    /// UPER constrained whole number: ceil(log2(range)) bits.
    mutating func constrained(_ lo: Int, _ hi: Int) -> Int {
        let range = hi - lo + 1
        if range <= 1 { return lo }
        return lo + bits(Int.bitWidth - (range - 1).leadingZeroBitCount)
    }

    /// ReferencePosition (123 bits): lat (31), lon (32), ellipse (36), alt (20), altConf (4).
    mutating func referencePosition() -> (latitude: Double?, longitude: Double?, altitudeM: Double?) {
        let latRaw = constrained(-900_000_000, 900_000_001)
        let lonRaw = constrained(-1_800_000_000, 1_800_000_001)
        skip(36)
        let altRaw = constrained(-100_000, 800_001)
        skip(4)
        let lat = latRaw != 900_000_001 && (-900_000_000...900_000_000).contains(latRaw) ? Double(latRaw) / 1e7 : nil
        let lon = lonRaw != 1_800_000_001 && (-1_800_000_000...1_800_000_000).contains(lonRaw) ? Double(lonRaw) / 1e7 : nil
        let alt = altRaw != 800_001 && (-100_000...800_000).contains(altRaw) ? Double(altRaw) / 100.0 : nil
        return (lat, lon, alt)
    }
}

/// SPATEM (ETSI EN 302 637-3): phase of the first movement event of the first intersection.
/// Port of android SpatTemParser.kt. Unsecured v2 payloads only.
enum SpatTemParser {
    enum Phase { case red, yellow, green, unknown }

    static func extractPhase(_ p: [UInt8], btpOff: Int) -> Phase {
        let its = btpOff + 4
        guard its + 6 <= p.count, p[its] == 2, p[its + 1] == 4 else { return .unknown }
        var b = BitReader(p, startByte: its + 6)
        b.bit()
        let spatOpt = b.bits(2)
        if spatOpt >> 1 & 1 == 1 { b.skip(20) }
        if spatOpt & 1 == 1 { b.skip(b.constrained(1, 63) * 8) }
        _ = b.constrained(1, 32)                       // IntersectionStateList count
        b.bit()
        let intOpt = b.bits(6)
        if intOpt >> 5 & 1 == 1 { b.skip(b.constrained(1, 63) * 8) }
        if b.bit() == 1 { b.skip(16) }                 // region
        b.skip(16 + 7 + 16)                            // id, revision, status
        if intOpt >> 4 & 1 == 1 { b.skip(20) }         // moy
        if intOpt >> 3 & 1 == 1 { b.skip(16) }         // timeStamp
        if intOpt >> 2 & 1 == 1 { b.skip(b.constrained(1, 16) * 8) } // enabledLanes
        _ = b.constrained(1, 255)                      // MovementList count
        b.bit()
        let movOpt = b.bits(3)
        if movOpt >> 2 & 1 == 1 { b.skip(b.constrained(1, 63) * 8) }
        b.skip(8)                                      // signalGroup
        _ = b.constrained(1, 16)                       // MovementEventList count
        b.skip(1 + 3)
        switch b.constrained(0, 8) {                   // MovementPhaseState
        case 3: return .red
        case 7, 8: return .yellow
        case 5, 6: return .green
        default: return .unknown
        }
    }
}

/// DENM (ETSI EN 302 637-3 v1.3.x): eventPosition, stationType, causeCode / subCauseCode. Port of android DenmParser.kt.
enum DenmParser {
    struct Cause: Equatable {
        let causeCode: Int
        let subCauseCode: Int

        var label: String { causeLabels[causeCode] ?? "Code \(causeCode)" }
        var sublabel: String {
            let table: [Int: String]?
            switch causeCode {
            case 1: table = subTraffic
            case 2: table = subAccident
            case 14: table = subSlow
            case 91: table = subBreakdown
            case 94: table = subStationary
            default: table = nil
            }
            if let t = table { return t[subCauseCode] ?? "/\(subCauseCode)" }
            return subCauseCode == 0 ? "" : "/\(subCauseCode)"
        }
    }

    struct Info: Equatable {
        let cause: Cause?
        let latitude: Double?
        let longitude: Double?
        let altitudeM: Double?
        let stationType: Int
    }

    static func extractCause(_ p: [UInt8], btpOff: Int) -> Cause? {
        parse(p, btpOff: btpOff)?.cause
    }

    static func parse(_ p: [UInt8], btpOff: Int) -> Info? {
        let its = btpOff + 4
        guard its + 6 <= p.count, p[its] == 2, p[its + 1] == 1 else { return nil }
        var b = BitReader(p, startByte: its + 6)
        // DENM body (no extension marker): situation, location, alacarte present.
        let sitPresent = b.bit()
        b.skip(2)
        // ManagementContainer: extension marker, then 5 optional-field flags.
        // Extension additions would follow stationType and shift everything after it.
        guard b.bit() == 0 else { return nil }
        let term = b.bit(), relDist = b.bit(), relDir = b.bit(), valDur = b.bit(), transInt = b.bit()
        b.skip(48)                                     // ActionID
        b.skip(84)                                     // detectionTime + referenceTime
        if term == 1 { b.skip(1) }
        let pos = b.referencePosition()                // eventPosition (123 bits)
        if relDist == 1 { b.skip(3) }
        if relDir == 1 { b.skip(2) }
        if valDur == 1 { b.skip(17) }
        if transInt == 1 { b.skip(14) }
        let stationType = b.bits(8)
        let cause: Cause?
        if sitPresent == 1 {
            // SituationContainer: ext marker, linkedCause + eventHistory present, informationQuality (3),
            // then CauseCode: ext marker, causeCode (8), subCauseCode (8).
            b.skip(1 + 2 + 3 + 1)
            cause = Cause(causeCode: b.bits(8), subCauseCode: b.bits(8))
        } else {
            cause = nil
        }
        return Info(cause: cause, latitude: pos.latitude, longitude: pos.longitude,
                    altitudeM: pos.altitudeM, stationType: stationType)
    }

    private static let causeLabels: [Int: String] = [
        1: "Verkehrsbehinderung", 2: "Unfall", 3: "Baustelle", 6: "Gefährliche Fahrbahn",
        9: "Hindernis", 12: "Fußgänger auf Fahrbahn", 14: "Geisterfahrer", 15: "Rettungseinsatz",
        17: "Extremwetter", 18: "Sichtbehinderung", 19: "Starkregen/Schnee", 26: "Langsamfahrer",
        27: "Stauende", 91: "Fahrzeugpanne", 92: "Nach Unfall", 93: "Personenproblem",
        94: "Stehendes Fahrzeug", 95: "Einsatzfahrzeug", 96: "Gefährliche Kurve",
        97: "Kollisionsrisiko", 98: "Rotlichtverstoß", 99: "Gefährliche Situation",
    ]
    private static let subTraffic: [Int: String] = [0: "", 1: "(erhöhtes Aufkommen)", 2: "(Stau bildend)", 3: "(Stau)", 4: "(dicker Stau)", 5: "(Stau stehend)", 6: "(stockend)"]
    private static let subAccident: [Int: String] = [0: "", 1: "(ohne Einsatz)", 2: "(mit Einsatz)", 3: "(mehrf. Unfälle)", 4: "(Hindernis)", 5: "(Aquaplaning)", 6: "(Eis)"]
    private static let subSlow: [Int: String] = [0: "", 1: "(Gefahrgut)", 2: "(Fahrzeugpanne)", 3: "(Baustelle)", 4: "(links überholen)"]
    private static let subBreakdown: [Int: String] = [0: "", 1: "(ohne Gefahr)", 2: "(Panne m. Feuer)", 3: "(Flüssigkeit)", 4: "(Gefahrgut)", 5: "(Unbekannt)"]
    private static let subStationary: [Int: String] = [0: "", 1: "(m. Gefahren)", 2: "(Pannenhilfe)", 3: "(Fahrzeugpanne)", 4: "(Unfall)", 5: "(Gefährl. Fahrzeug)"]
}

/// CAM (EN 302 637-2 v1.4, CDD v1.3): vehicle state from basic, high-, low-frequency & special-vehicle containers.
enum CamParser {
    enum DriveDirection: Int, Equatable {
        case forward = 0, backward = 1
        var label: String { self == .forward ? "Vorwärts" : "Rückwärts" }
    }

    enum VehicleRole: Int, Equatable {
        case standard = 0, publicTransport = 1, specialTransport = 2, dangerousGoods = 3,
             roadWork = 4, rescue = 5, emergency = 6, safetyCar = 7, agriculture = 8,
             commercial = 9, military = 10, roadOperator = 11, taxi = 12

        var label: String {
            switch self {
            case .standard: "Standard"
            case .publicTransport: "ÖPNV"
            case .specialTransport: "Schwertransport"
            case .dangerousGoods: "Gefahrgut"
            case .roadWork: "Baustelle"
            case .rescue: "Rettung"
            case .emergency: "Einsatzfahrzeug"
            case .safetyCar: "Sicherheitsfahrzeug"
            case .agriculture: "Landwirtschaft"
            case .commercial: "Gewerbe"
            case .military: "Militär"
            case .roadOperator: "Straßenbetrieb"
            case .taxi: "Taxi"
            }
        }
    }

    struct State: Equatable {
        var stationType: Int?
        var altitudeM: Double?
        var speedMps: Double?
        var headingDeg: Double?
        var driveDirection: DriveDirection?
        var lengthM: Double?
        var widthM: Double?
        var longAccel: Double?          // m/s², negative = braking
        var curvature: Int?             // CDD v1.3: -1023..1022, unit 1/10000 m⁻¹, + = left, - = right, 0 = straight
        var yawRateDegPerSec: Double?   // °/s, + = counter-clockwise / left
        var control: Control?           // only if the sender includes accelerationControl
        var lanePosition: Int?          // -1 = offRoad, 0 = innerShoulder, 1..13 = lanes, 14 = outerShoulder
        var steeringWheelDeg: Double?   // degrees, 1.5° resolution
        var latAccel: Double?           // m/s²
        var vertAccel: Double?          // m/s²
        var performanceClass: Int?      // 1..7
        var vehicleRole: VehicleRole?   // only in low-frequency CAMs
        var lights: Lights?             // only in low-frequency CAMs (every ~500 ms)
        var pathHistoryCount: Int?
        var lightBar: Bool?             // SpecialVehicleContainer: blue/amber beacon active
        var siren: Bool?                // SpecialVehicleContainer: siren active

        /// Turning radius in meters (signed: + left, - right), nil if straight or unknown.
        var curveRadiusM: Double? {
            guard let c = curvature, c != 0 else { return nil }
            return 10_000.0 / Double(c)
        }
    }

    /// AccelerationControl BIT STRING, bit 0 first.
    struct Control: OptionSet, Equatable {
        let rawValue: Int
        static let brakePedal = Control(rawValue: 1 << 6)
        static let gasPedal = Control(rawValue: 1 << 5)
        static let emergencyBrake = Control(rawValue: 1 << 4)
        static let collisionWarning = Control(rawValue: 1 << 3)
        static let acc = Control(rawValue: 1 << 2)
        static let cruiseControl = Control(rawValue: 1 << 1)
        static let speedLimiter = Control(rawValue: 1 << 0)
    }

    /// ExteriorLights BIT STRING, bit 0 first.
    struct Lights: OptionSet, Equatable {
        let rawValue: Int
        static let lowBeam = Lights(rawValue: 1 << 7)
        static let highBeam = Lights(rawValue: 1 << 6)
        static let leftTurn = Lights(rawValue: 1 << 5)
        static let rightTurn = Lights(rawValue: 1 << 4)
        static let daytime = Lights(rawValue: 1 << 3)
        static let reverse = Lights(rawValue: 1 << 2)
        static let fog = Lights(rawValue: 1 << 1)
        static let parking = Lights(rawValue: 1 << 0)
    }

    static func parse(_ p: [UInt8], btpOff: Int) -> State? {
        let its = btpOff + 4
        guard its + 6 <= p.count, (1...2).contains(p[its]), p[its + 1] == 2 else { return nil }
        var b = BitReader(p, startByte: its + 6)
        b.skip(16)                                      // generationDeltaTime
        b.skip(1)                                       // CamParameters extension marker
        let lfPresent = b.bit()
        let svPresent = b.bit()

        // BasicContainer: ext (1), stationType (8), referencePosition (123)
        b.skip(1)
        var s = State()
        s.stationType = b.bits(8)
        let refPos = b.referencePosition()
        s.altitudeM = refPos.altitudeM

        guard b.bit() == 0, b.bit() == 0 else { return s }  // HF choice: not extended, basicVehicle (RSU returns basic info)
        let accCtl = b.bit(), lane = b.bit(), steer = b.bit(), latAcc = b.bit(), vertAcc = b.bit(), perf = b.bit(), toll = b.bit()

        let heading = b.bits(12); b.skip(7)
        let speed = b.bits(14); b.skip(7)
        if heading <= 3600 { s.headingDeg = Double(heading) / 10 }
        if speed < 16383 { s.speedMps = Double(speed) / 100 }

        let dir = b.bits(2)
        s.driveDirection = DriveDirection(rawValue: dir)

        let lenVal = b.constrained(1, 1023); b.skip(3)
        if (1...1021).contains(lenVal) { s.lengthM = Double(lenVal) / 10 }
        let widVal = b.constrained(1, 62)
        if (1...60).contains(widVal) { s.widthM = Double(widVal) / 10 }

        let acc = b.constrained(-160, 161); b.skip(7)
        if acc != 161 { s.longAccel = Double(acc) / 10 }

        let curv = b.constrained(-1023, 1023); b.skip(3)
        if curv != 1023 { s.curvature = curv }
        b.skip(1 + 2)                                   // curvatureCalculationMode (extensible enum)

        let yaw = b.constrained(-32766, 32767); b.skip(4)
        if yaw != 32767 { s.yawRateDegPerSec = Double(yaw) / 100 }

        if accCtl == 1 { s.control = Control(rawValue: b.bits(7)) }
        if lane == 1 { s.lanePosition = b.constrained(-1, 14) }
        if steer == 1 {
            let sw = b.constrained(-511, 512); b.skip(7)
            if sw != 512 { s.steeringWheelDeg = Double(sw) * 1.5 }
        }
        if latAcc == 1 {
            let la = b.constrained(-160, 161); b.skip(7)
            if la != 161 { s.latAccel = Double(la) / 10 }
        }
        if vertAcc == 1 {
            let va = b.constrained(-160, 161); b.skip(7)
            if va != 161 { s.vertAccel = Double(va) / 10 }
        }
        if perf == 1 {
            let pc = b.bits(3)
            if pc > 0 { s.performanceClass = pc }
        }
        guard toll == 0 else { return s }

        if lfPresent == 1 {
            guard b.bit() == 0 else { return s }        // LF choice extension
            s.vehicleRole = VehicleRole(rawValue: b.bits(4))
            s.lights = Lights(rawValue: b.bits(8))
            if b.pos + 6 <= b.b.count * 8 {
                let count = b.constrained(0, 40)
                s.pathHistoryCount = count
                if svPresent == 1 {
                    for _ in 0..<count {
                        let hasDelta = b.bit()
                        b.skip(18 + 18 + 15)            // DeltaReferencePosition
                        if hasDelta == 1 {
                            guard b.bit() == 0 else { return s } // PathDeltaTime ext marker (1..65535, ...)
                            b.skip(16)
                        }
                    }
                }
            }
        }

        if svPresent == 1, b.pos + 4 <= b.b.count * 8, b.bit() == 0 {
            let choice = b.constrained(0, 6)
            switch choice {
            case 1: // specialTransportContainer: specialTransportType(4), lightBarSirenInUse(2)
                b.skip(4)
                readLightBarSiren(&b, into: &s)
            case 3: // roadWorksContainerBasic: opt(2), [subCause(8)], lightBarSirenInUse(2)
                let hasSub = b.bit(); _ = b.bit()
                if hasSub == 1 { b.skip(8) }
                readLightBarSiren(&b, into: &s)
            case 4: // rescueContainer: lightBarSirenInUse(2)
                readLightBarSiren(&b, into: &s)
            case 5: // emergencyContainer: opt(2), lightBarSirenInUse(2)
                b.skip(2)
                readLightBarSiren(&b, into: &s)
            case 6: // safetyCarContainer: opt(3), lightBarSirenInUse(2)
                b.skip(3)
                readLightBarSiren(&b, into: &s)
            default:
                break
            }
        }
        return s
    }

    private static func readLightBarSiren(_ b: inout BitReader, into s: inout State) {
        guard b.pos + 2 <= b.b.count * 8 else { return }
        let v = b.bits(2)
        s.lightBar = (v & 0b10) != 0
        s.siren = (v & 0b01) != 0
    }
}
