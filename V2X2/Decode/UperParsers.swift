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
