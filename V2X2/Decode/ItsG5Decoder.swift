import SwiftUI

/// Minimal 802.11p / LLC-SNAP / GeoNetworking / BTP decoder.
/// Port of android ItsG5Decoder.kt (MIT, Peter Holzhauser and contributors) — keep both in sync.
///
///   [802.11 MAC header 24/26/30/32 B][LLC/SNAP 8 B][GN Basic 4 B][GN Common 8 B]
///   [GN Extended N B][BTP-B 4 B][ASN.1 UPER payload]
enum ItsG5Decoder {
    static let etherTypeItsG5 = 0x8947
    private static let hdrLengths = [24, 26, 30, 32]

    struct Decoded {
        var etherType: Int?
        var msgType: MsgType = .unknown
        var stationId: UInt64?
        var stationType: Int?
        var latitude: Double?
        var longitude: Double?
        var headingDeg: Double?
        var speedMps: Double?
        var btpDstPort: Int?
        var spatPhase: SpatTemParser.Phase?
        var denmCause: DenmParser.Cause?
        var cam: CamParser.State?
        var secured: Bool?
    }

    static func decode(_ p: [UInt8]) -> Decoded {
        let et = sniffEtherType(p)
        guard et == etherTypeItsG5 else { return Decoded(etherType: et) }

        for hdrLen in hdrLengths {
            guard p.count >= hdrLen + 8 + 4 + 8, hasSnap(p, hdrLen) else { continue }
            let basicOff = hdrLen + 8
            let commonOff = basicOff + 4

            // GN Basic Header NH == 2 → IEEE 1609.2 secured; the common header sits inside the envelope.
            let secured = (p[basicOff] & 0x0F) == 2
            let innerOff: Int
            if secured {
                guard let o = findInnerGnCommonHeader(p, start: commonOff, end: min(commonOff + 20, p.count - 36)) else { continue }
                innerOff = o
            } else {
                innerOff = commonOff
            }
            guard p.count >= innerOff + 8 else { continue }

            let ht = Int(p[innerOff + 1] >> 4)
            let hst = Int(p[innerOff + 1] & 0x0F)
            let extHdrLen: Int
            switch ht {
            case 1: extHdrLen = 4   // BEACON
            case 2: extHdrLen = 48  // GUC
            case 3: extHdrLen = 56  // GAC
            case 4: extHdrLen = 44  // GBC
            case 5: extHdrLen = 28  // SHB / TSB
            case 6: extHdrLen = 36  // LS
            default: extHdrLen = 28
            }
            // SHB puts the source LPV first; GBC/GAC/GUC/TSB prepend seq number + reserved.
            let srcPosOff = innerOff + 8 + ((ht == 5 && hst == 0) ? 0 : 4)
            let btpOff = innerOff + 8 + extHdrLen
            guard p.count >= btpOff + 4, p.count >= srcPosOff + 24 else { continue }

            // Source Long Position Vector: GnAddr 8 | TST 4 | LAT 4 | LON 4 | PAI+speed 2 | heading 2
            let stationId = p[srcPosOff ..< srcPosOff + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let stationType = Int(p[srcPosOff] >> 2) & 0x1F

            var latRaw = be32(p, srcPosOff + 12)
            var lonRaw = be32(p, srcPosOff + 16)
            var pshOff = srcPosOff + 20
            // Some RSUs use an 8-byte TAI timestamp, shifting the position by 4 bytes.
            if !(-90.0...90.0).contains(Double(latRaw) / 1e7), p.count >= srcPosOff + 28 {
                let latS = be32(p, srcPosOff + 16), lonS = be32(p, srcPosOff + 20)
                if (-90.0...90.0).contains(Double(latS) / 1e7), (-180.0...180.0).contains(Double(lonS) / 1e7) {
                    latRaw = latS; lonRaw = lonS; pshOff = srcPosOff + 24
                }
            }
            let psh = UInt32(bitPattern: be32(p, pshOff))
            let speedRaw = Int((psh >> 16) & 0x7FFF)
            let speed = Double(speedRaw >= 0x4000 ? speedRaw - 0x8000 : speedRaw) / 100.0
            let headingRaw = Int(psh & 0xFFFF)

            let lat = Double(latRaw) / 1e7, lon = Double(lonRaw) / 1e7
            let hasPos = (-90.0...90.0).contains(lat) && (-180.0...180.0).contains(lon) && (lat != 0 || lon != 0)

            let dstPort = Int(p[btpOff]) << 8 | Int(p[btpOff + 1])
            let msgType = MsgType(btpPort: dstPort)

            return Decoded(
                etherType: et,
                msgType: msgType,
                stationId: stationId,
                stationType: stationType,
                latitude: hasPos ? lat : nil,
                longitude: hasPos ? lon : nil,
                headingDeg: hasPos && headingRaw != 0xFFFF ? Double(headingRaw) / 10.0 : nil,
                speedMps: hasPos ? speed : nil,
                btpDstPort: dstPort,
                spatPhase: msgType == .spatem ? SpatTemParser.extractPhase(p, btpOff: btpOff) : nil,
                denmCause: msgType == .denm ? DenmParser.extractCause(p, btpOff: btpOff) : nil,
                cam: msgType == .cam ? CamParser.parse(p, btpOff: btpOff) : nil,
                secured: secured
            )
        }
        return Decoded(etherType: et)
    }

    static func sniffEtherType(_ p: [UInt8]) -> Int? {
        for hdrLen in hdrLengths where p.count >= hdrLen + 8 && hasSnap(p, hdrLen) {
            return Int(p[hdrLen + 6]) << 8 | Int(p[hdrLen + 7])
        }
        return nil
    }

    private static func hasSnap(_ p: [UInt8], _ o: Int) -> Bool {
        p[o] == 0xAA && p[o + 1] == 0xAA && p[o + 2] == 0x03 && p[o + 3] == 0 && p[o + 4] == 0 && p[o + 5] == 0
    }

    private static func be32(_ p: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3]))
    }

    /// Inner GN Common Header inside a 1609.2 envelope: NH ∈ 0…2, HT ∈ 4…6, payload length 1…999.
    private static func findInnerGnCommonHeader(_ p: [UInt8], start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
        for off in start..<end {
            if off + 8 > p.count { break }
            let nh = p[off] >> 4, ht = p[off + 1] >> 4
            let plen = Int(p[off + 4]) << 8 | Int(p[off + 5])
            if nh <= 2, (4...6).contains(ht), (1...999).contains(plen) { return off }
        }
        return nil
    }
}

enum MsgType: String, CaseIterable {
    case unknown = "?", cam = "CAM", denm = "DENM", mapem = "MAPEM", spatem = "SPATEM",
         ivim = "IVIM", srem = "SREM", ssem = "SSEM", tlm = "TLM", rtcmem = "RTCMEM"

    init(btpPort: Int) {
        switch btpPort {
        case 2001: self = .cam
        case 2002: self = .denm
        case 2003: self = .mapem
        case 2004: self = .spatem
        case 2006: self = .ivim
        case 2007: self = .srem
        case 2008: self = .ssem
        case 2010: self = .tlm
        case 2012: self = .rtcmem
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .unknown: "Unbekannt"
        case .cam: "Fahrzeugposition"
        case .denm: "Gefahrenmeldung"
        case .mapem: "Kreuzungsgeometrie"
        case .spatem: "Ampelphase"
        case .ivim: "Fahrzeuginfo"
        case .srem: "Signalanfrage"
        case .ssem: "Signalstatus"
        case .tlm: "Verkehrslicht"
        case .rtcmem: "Korrekturdaten"
        }
    }

    /// Same tones as the Android marker drawables.
    var rgb: UInt32 {
        switch self {
        case .unknown: 0x607D8B
        case .cam: 0x1976D2
        case .denm: 0xE65100
        case .mapem: 0x7B1FA2
        case .spatem: 0x388E3C
        case .ivim: 0xC2185B
        case .srem, .ssem: 0x00838F
        case .tlm: 0xAFB42B
        case .rtcmem: 0x455A64
        }
    }

    var color: Color {
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    var symbol: String {
        switch self {
        case .cam: "car.fill"
        case .denm: "exclamationmark.triangle.fill"
        case .spatem, .tlm, .ssem, .srem: "light.beacon.max.fill"
        case .mapem: "map.fill"
        case .ivim: "info.circle.fill"
        default: "dot.radiowaves.left.and.right"
        }
    }
}
