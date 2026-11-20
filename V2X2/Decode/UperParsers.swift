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

/// DENM (ETSI EN 302 637-3 v1.3.x): causeCode / subCauseCode. Port of android DenmParser.kt.
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

    static func extractCause(_ p: [UInt8], btpOff: Int) -> Cause? {
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
        b.skip(123)                                    // eventPosition
        if relDist == 1 { b.skip(3) }
        if relDir == 1 { b.skip(2) }
        if valDur == 1 { b.skip(17) }
        if transInt == 1 { b.skip(14) }
        b.skip(8)                                      // stationType
        guard sitPresent == 1 else { return nil }
        // SituationContainer: ext marker, linkedCause + eventHistory present, informationQuality (3),
        // then CauseCode: ext marker, causeCode (8), subCauseCode (8).
        b.skip(1 + 2 + 3 + 1)
        return Cause(causeCode: b.bits(8), subCauseCode: b.bits(8))
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

/// CAM (EN 302 637-2 v1.4, CDD v1.3): vehicle state from the basic-vehicle high/low-frequency containers.
enum CamParser {
    struct State: Equatable {
        var speedMps: Double?
        var headingDeg: Double?
        var longAccel: Double?          // m/s², negative = braking
        var control: Control?           // only if the sender includes accelerationControl
        var lights: Lights?             // only in low-frequency CAMs (every ~500 ms)
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
        b.skip(1)                                       // specialVehicleContainer present
        b.skip(1 + 8 + 123)                             // BasicContainer: ext, stationType, referencePosition
        guard b.bit() == 0, b.bit() == 0 else { return nil }  // HF choice: not extended, basicVehicle (not RSU)
        let accCtl = b.bit(), lane = b.bit(), steer = b.bit(), latAcc = b.bit(), vertAcc = b.bit(), perf = b.bit(), toll = b.bit()

        var s = State()
        let heading = b.bits(12); b.skip(7)
        let speed = b.bits(14); b.skip(7)
        if heading <= 3600 { s.headingDeg = Double(heading) / 10 }
        if speed < 16383 { s.speedMps = Double(speed) / 100 }
        b.skip(2)                                       // driveDirection
        b.skip(10 + 3)                                  // vehicleLength
        b.skip(6)                                       // vehicleWidth
        let acc = b.bits(9) - 160; b.skip(7)
        if acc != 161 { s.longAccel = Double(acc) / 10 }
        b.skip(11 + 3)                                  // curvature
        b.skip(1 + 2)                                   // curvatureCalculationMode (extensible enum)
        b.skip(16 + 4)                                  // yawRate
        if accCtl == 1 { s.control = Control(rawValue: b.bits(7)) }
        guard lfPresent == 1, toll == 0 else { return s }
        if lane == 1 { b.skip(4) }
        if steer == 1 { b.skip(10 + 7) }
        if latAcc == 1 { b.skip(9 + 7) }
        if vertAcc == 1 { b.skip(9 + 7) }
        if perf == 1 { b.skip(3) }
        guard b.bit() == 0 else { return s }            // LF choice extension
        b.skip(4)                                       // vehicleRole
        s.lights = Lights(rawValue: b.bits(8))
        return s
    }
}
