import AppKit
import SwiftUI

/// The Mectrics "M", drawn in code from the app icon's geometry.
///
/// Drawing it instead of shipping an asset keeps the menu bar logo crisp at every backing
/// scale, and one outline serves both the template image and SwiftUI. The geometry is in the
/// app icon's own pixels (the M spans 565 × 390 of the 1024 px icon) with y pointing down, so
/// the outline can be laid over the icon and checked against it directly.
enum MectricsGlyph {
    /// Width : height of the M.
    static let aspectRatio: CGFloat = size.width / size.height

    /// The tip's pink, sampled from the app icon.
    static let tipColor = NSColor(srgbRed: 254 / 255, green: 76 / 255, blue: 103 / 255, alpha: 1)

    /// The whole M outline (tip included) fitted into `rect`, aspect preserved, centered.
    /// Like SwiftUI and a flipped `NSImage`, y points down.
    static func path(in rect: CGRect) -> CGPath {
        fitted(outline, in: rect)
    }

    /// Only the colored tip region, in the same coordinate space as `path(in:)`.
    static func tipPath(in rect: CGRect) -> CGPath {
        fitted(tip, in: rect)
    }

    /// Template (monochrome) menu bar image, `height` points tall, isTemplate = true,
    /// resolution independent (NSImage(size:flipped:drawingHandler:)).
    ///
    /// A template image follows light, dark and tinted menu bars on its own, so it never
    /// needs to be redrawn or reassigned when the appearance changes. The width is whole
    /// points: AppKit snaps an image to whole pixels, and a fractional width has the drawn
    /// logo resampled, and softened, to fit. It is rounded down so the M spans it edge to
    /// edge and both stems' outer edges fall on pixel boundaries even at 1x.
    /// The tip is not set apart here; at menu bar size a seam reads as a broken stem.
    static func templateImage(height: CGFloat, badge symbolName: String? = nil) -> NSImage {
        let size = NSSize(width: (height * aspectRatio).rounded(.down), height: height)
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            guard let symbolName else {
                context.addPath(path(in: bounds))
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
                return true
            }
            let badge = badgeRect(in: bounds)
            // The M first, with a round gap punched around the badge. Even-odd against
            // the full bounds turns the disc into a hole rather than a second shape.
            context.saveGState()
            context.addRect(bounds)
            context.addEllipse(in: badge.insetBy(dx: -badgeGap, dy: -badgeGap))
            context.clip(using: .evenOdd)
            context.addPath(path(in: bounds))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            drawBadge(symbolName, in: badge, context: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The fixed menu bar image, built once: 20 × 14 pt. The M is a heavy, wide mark, so it
    /// stands a little shorter than a system symbol to carry the same visual weight. Both
    /// sides are even, so it centers on whole pixels in an even-width item and menu bar at 1x.
    static let menuBarImage: NSImage = templateImage(height: 14)

    /// The menu bar logo carrying a state badge, or the plain logo when `symbolName` is nil.
    ///
    /// The badge is how the single icon reports health without a second item beside it.
    /// It is **the same size as the plain logo**, because the item reserves a fixed width
    /// and a mark that grew when something went wrong would move every item after it.
    /// Built once per symbol: this changes on a severity transition, which is rare, and
    /// never on a sampling cycle.
    @MainActor
    static func menuBarImage(badge symbolName: String?) -> NSImage {
        guard let symbolName else { return menuBarImage }
        if let cached = badgedMenuBarImages[symbolName] { return cached }
        let image = templateImage(height: menuBarHeight, badge: symbolName)
        badgedMenuBarImages[symbolName] = image
        return image
    }

    /// Height of the menu bar logo, badged or not.
    static let menuBarHeight: CGFloat = 14

    @MainActor
    private static var badgedMenuBarImages: [String: NSImage] = [:]

    /// The badge's square, at the trailing-bottom corner: the foot of the right stem,
    /// which carries the least of what makes the M recognizable.
    private static func badgeRect(in bounds: CGRect) -> CGRect {
        let side = (bounds.height * badgeScale).rounded()
        return CGRect(
            x: bounds.maxX - side,
            y: bounds.maxY - side,
            width: side,
            height: side
        )
    }

    /// Badge side as a fraction of the logo's height. Large enough for a triangle and
    /// an octagon to read apart at menu bar size, small enough to leave the M standing.
    private static let badgeScale: CGFloat = 0.62

    /// Clearance punched out of the M around the badge, so the two read as two marks
    /// rather than one blob. In points at the logo's natural size.
    private static let badgeGap: CGFloat = 1.2

    /// Draws `symbolName` into `rect` as opaque black, for a template image's alpha.
    ///
    /// The enclosing handler's context has y pointing down (`flipped: true`), and
    /// drawing a bitmap there would mirror it, so the flip is undone around this draw.
    private static func drawBadge(
        _ symbolName: String,
        in rect: CGRect,
        context: CGContext
    ) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: rect.height,
            weight: .bold
        )
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration),
            let cgImage = symbol.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        else { return }
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        // A symbol is a black glyph on transparent, so its own alpha is the coverage a
        // template image needs — no mask or fill colour of our own.
        context.draw(cgImage, in: rect)
        context.restoreGState()
    }
}

/// SwiftUI rendering of the logo, M in `.primary`, tip in the brand pink (or monochrome).
struct MectricsGlyphView: View {
    var showsTip: Bool = true

    private static let tipColor = Color(nsColor: MectricsGlyph.tipColor)

    var body: some View {
        ZStack {
            MectricsGlyphShape(part: showsTip ? .underTip : .whole)
                .fill(.primary)
            if showsTip {
                MectricsGlyphShape(part: .tip)
                    .fill(Self.tipColor)
            }
        }
        .aspectRatio(MectricsGlyph.aspectRatio, contentMode: .fit)
    }
}

private struct MectricsGlyphShape: Shape {
    enum Part { case whole, underTip, tip }
    let part: Part

    func path(in rect: CGRect) -> Path {
        switch part {
        case .whole: Path(MectricsGlyph.path(in: rect))
        case .underTip: Path(MectricsGlyph.fitted(MectricsGlyph.underTip, in: rect))
        case .tip: Path(MectricsGlyph.tipPath(in: rect))
        }
    }
}

// MARK: - Geometry

// Fitted to the app icon's anti-aliased edge: no point of this outline strays more than
// 2 px (0.3% of the M's width) from it, which is below what any on-screen size can show.
extension MectricsGlyph {
    fileprivate static let size = CGSize(width: 565, height: 390)

    /// Stem width; the diagonals are the same ribbon seen at an angle.
    private static let stem: CGFloat = 71
    /// Both stems end in the same slanted cut, lower on the right (dy per dx).
    private static let cutSlope: CGFloat = 2 / 3
    /// The cut meets a stem's inner edge in a soft corner and its outer edge in a sharp one.
    private static let footRadius: CGFloat = 24.5
    /// How far a diagonal's edges move sideways per unit they descend.
    private static let run: CGFloat = 0.495
    /// Unit direction of the left diagonal, running down to the valley.
    private static let down = CGVector(dx: run, dy: 1).normalized

    /// The left diagonal's upper and lower edges as x at y = 0; the right diagonal mirrors them.
    private static let upperEdge: CGFloat = 114
    private static let lowerEdge: CGFloat = 35.6

    /// The outer shoulder is not a circle: it rises from the stem's outer edge in a tight
    /// turn, peaks `shoulderTop` in from that edge, and eases into the diagonal far more
    /// slowly, joining it at `shoulderJoin`.
    private static let shoulderTop: CGFloat = 70
    private static let shoulderRise: CGFloat = 64.5
    private static let shoulderRiseHandle: CGFloat = 0.55
    private static let shoulderTopHandle: CGFloat = 0.62
    private static let shoulderJoin: CGFloat = 89.5
    private static let shoulderOutHandle: CGFloat = 44.5
    private static let shoulderInHandle: CGFloat = 43

    /// The inner notch between a stem and its diagonal is nearly a point.
    private static let notchRadius: CGFloat = 8
    private static let valleyRadius: CGFloat = 57.5
    /// The valley's underside leaves the diagonals at `valleyDeparture` and bottoms out at
    /// `valleyBottom`, a deeper and rounder turn than the valley's inside.
    private static let valleyDeparture: CGFloat = 258
    private static let valleyBottom: CGFloat = 356
    private static let valleySideHandle: CGFloat = 54
    private static let valleyBottomHandle: CGFloat = 53

    /// The tip's top edge, as y where it meets the right stem's inner and outer edges. The
    /// icon draws it a little flatter than the cut below it.
    private static let tipTop = (inner: CGFloat(280.3), outer: CGFloat(321.7))

    private static func upper(_ y: CGFloat, mirrored: Bool = false) -> CGPoint {
        let x = upperEdge + run * y
        return CGPoint(x: mirrored ? size.width - x : x, y: y)
    }

    private static func lower(_ y: CGFloat, mirrored: Bool = false) -> CGPoint {
        let x = lowerEdge + run * y
        return CGPoint(x: mirrored ? size.width - x : x, y: y)
    }

    fileprivate static let outline: CGPath = {
        let w = size.width, h = size.height
        let midX = w / 2
        let footY = h - stem * cutSlope
        let valleyY = (size.width - 2 * upperEdge) / (2 * run)
        let notchY = (stem - lowerEdge) / run
        let top = shoulderTop, rise = shoulderRise
        let topHandle = shoulderTopHandle * top, riseHandle = shoulderRiseHandle * rise

        let path = CGMutablePath()
        // Left stem, from its sharp bottom-right corner, clockwise.
        path.move(to: CGPoint(x: stem, y: h))
        path.addArc(tangent1End: CGPoint(x: 0, y: footY), tangent2End: .zero, radius: footRadius)
        path.addLine(to: CGPoint(x: 0, y: rise))
        path.addCurve(to: CGPoint(x: top, y: 0),
                      control1: CGPoint(x: 0, y: rise - riseHandle),
                      control2: CGPoint(x: top - topHandle, y: 0))
        let leftJoin = upper(shoulderJoin)
        path.addCurve(to: leftJoin,
                      control1: CGPoint(x: top + shoulderOutHandle, y: 0),
                      control2: leftJoin - down * shoulderInHandle)
        // Down into the valley and up the right diagonal.
        let rightJoin = upper(shoulderJoin, mirrored: true)
        path.addArc(tangent1End: CGPoint(x: midX, y: valleyY), tangent2End: rightJoin, radius: valleyRadius)
        path.addLine(to: rightJoin)
        path.addCurve(to: CGPoint(x: w - top, y: 0),
                      control1: rightJoin - down.mirrored * shoulderInHandle,
                      control2: CGPoint(x: w - top - shoulderOutHandle, y: 0))
        path.addCurve(to: CGPoint(x: w, y: rise),
                      control1: CGPoint(x: w - top + topHandle, y: 0),
                      control2: CGPoint(x: w, y: rise - riseHandle))
        // Right stem, its slanted foot, and back up its inner edge.
        path.addLine(to: CGPoint(x: w, y: h))
        path.addArc(tangent1End: CGPoint(x: w - stem, y: footY),
                    tangent2End: CGPoint(x: w - stem, y: 0), radius: footRadius)
        let rightDeparture = lower(valleyDeparture, mirrored: true)
        path.addArc(tangent1End: CGPoint(x: w - stem, y: notchY),
                    tangent2End: rightDeparture, radius: notchRadius)
        // Under the valley.
        path.addLine(to: rightDeparture)
        let bottom = CGPoint(x: midX, y: valleyBottom)
        path.addCurve(to: bottom,
                      control1: rightDeparture + down.mirrored * valleySideHandle,
                      control2: CGPoint(x: midX + valleyBottomHandle, y: valleyBottom))
        let leftDeparture = lower(valleyDeparture)
        path.addCurve(to: leftDeparture,
                      control1: CGPoint(x: midX - valleyBottomHandle, y: valleyBottom),
                      control2: leftDeparture + down * valleySideHandle)
        path.addArc(tangent1End: CGPoint(x: stem, y: notchY),
                    tangent2End: CGPoint(x: stem, y: h), radius: notchRadius)
        path.closeSubpath()
        return path
    }()

    /// The right stem below the tip's top edge, that edge pushed down by `inset`.
    private static func belowTipEdge(inset: CGFloat) -> CGPath {
        let inner = size.width - stem - 1, outer = size.width + 1
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: inner, y: tipTop.inner + inset),
            CGPoint(x: outer, y: tipTop.outer + inset),
            CGPoint(x: outer, y: size.height + 1),
            CGPoint(x: inner, y: size.height + 1)
        ])
        path.closeSubpath()
        return path
    }

    /// Cut from the outline itself, so the tip can never drift from the stem it colors.
    fileprivate static let tip: CGPath = outline.intersection(belowTipEdge(inset: 0))

    /// The M with most of the tip removed. It still runs a little way under the tip: two
    /// fills that only meet edge to edge leave a background-colored seam between them, and
    /// filling the whole M under the tip would fringe the tip's outer edges instead.
    fileprivate static let underTip: CGPath = outline.subtracting(belowTipEdge(inset: 16))

    fileprivate static func fitted(_ path: CGPath, in rect: CGRect) -> CGPath {
        let scale = min(rect.width / size.width, rect.height / size.height)
        var transform = CGAffineTransform(
            translationX: rect.midX - size.width * scale / 2,
            y: rect.midY - size.height * scale / 2
        ).scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }
}

private extension CGVector {
    var normalized: CGVector {
        let length = (dx * dx + dy * dy).squareRoot()
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// The same direction reflected across the M's vertical axis.
    var mirrored: CGVector { CGVector(dx: -dx, dy: dy) }

    static func * (vector: CGVector, length: CGFloat) -> CGVector {
        CGVector(dx: vector.dx * length, dy: vector.dy * length)
    }
}

private extension CGPoint {
    static func + (point: CGPoint, offset: CGVector) -> CGPoint {
        CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
    }

    static func - (point: CGPoint, offset: CGVector) -> CGPoint {
        CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
    }
}
