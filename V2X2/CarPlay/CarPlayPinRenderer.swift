import SwiftUI
import UIKit

/// Draws the CarPlay pin badges. CarPlay can't animate pins, so `tick` (flipped by the caller every
/// second) selects an alternate look and the caller swaps the images: emergency blue/red, braking
/// full/light red, hazards with a pulsing halo.
final class CarPlayPinRenderer {
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 512
        return cache
    }()

    /// Pins stay within CarPlay's 40 pt limit.
    private static let canvas: CGFloat = 40
    private static let radius: CGFloat = 11

    static func headingBucket(for s: Station) -> Int? {
        guard s.msgType == .cam, s.stationType != 15, let h = s.headingDeg, h.isFinite else { return nil }
        return ((Int((h / 15).rounded()) % 24) + 24) % 24 * 15
    }

    static func animates(_ s: Station) -> Bool {
        s.isEmergency || s.msgType == .denm || (s.braking && s.msgType == .cam)
    }

    /// - Parameters:
    ///   - inactive: grey badge without animation (history entries that went quiet).
    ///   - heading: draws a direction wedge (nil = none); bucketed to 15° for the cache.
    func image(for s: Station, tick: Bool, selected: Bool, inactive: Bool = false, heading: Bool = true) -> UIImage {
        var fill = UIColor(s.tint(phase: true, brakingRed: true))
        var halo: CGFloat = selected ? 17 : 0
        var ringWidth: CGFloat = 2
        var wedge: Int?
        if inactive {
            fill = .systemGray
            halo = 0
        } else {
            if s.isEmergency {
                fill = tick ? .systemBlue : .systemRed
            } else if s.braking, s.msgType == .cam {
                fill = tick ? UIColor.systemRed : UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
            }
            if s.msgType == .denm {
                if selected {
                    halo = 19
                    ringWidth = 3.5
                } else {
                    halo = tick ? 17 : 13
                }
            }
            if heading {
                wedge = Self.headingBucket(for: s)
            }
        }
        let dark = !inactive && s.spatPhase == .yellow  // white symbol is unreadable on yellow
        let key = "\(s.symbol)|\(fill.hexKey)|\(wedge ?? -1)|\(halo)|\(ringWidth)|\(dark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = render(symbol: s.symbol, fill: fill, symbolColor: dark ? .black : .white, wedge: wedge, halo: halo, ringWidth: ringWidth)
        cache.setObject(img, forKey: key)
        return img
    }

    private func render(symbol: String, fill: UIColor, symbolColor: UIColor, wedge: Int?, halo: CGFloat, ringWidth: CGFloat) -> UIImage {
        let size = CGSize(width: Self.canvas, height: Self.canvas)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = Self.radius
        return UIGraphicsImageRenderer(size: size).image { rc in
            let ctx = rc.cgContext
            if halo > 0 {
                ctx.setFillColor(fill.withAlphaComponent(0.35).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2))
            }
            if let wedge {
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(wedge) * .pi / 180)  // 0° = north = up, clockwise
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.move(to: CGPoint(x: 0, y: -(r + 7)))
                ctx.addLine(to: CGPoint(x: 5, y: -(r + 1)))
                ctx.addLine(to: CGPoint(x: -5, y: -(r + 1)))
                ctx.closePath()
                ctx.fillPath()
                ctx.restoreGState()
            }
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: disc)
            ctx.restoreGState()
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(ringWidth)
            ctx.strokeEllipse(in: disc)

            let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            if let sym = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(symbolColor, renderingMode: .alwaysOriginal) {
                sym.draw(in: CGRect(x: c.x - sym.size.width / 2, y: c.y - sym.size.height / 2, width: sym.size.width, height: sym.size.height))
            }
        }
    }
}

private extension UIColor {
    var hexKey: String {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
        }
        var w: CGFloat = 0
        if getWhite(&w, alpha: &a) {
            return String(format: "w%.2f,%.2f", w, a)
        }
        return description
    }
}
