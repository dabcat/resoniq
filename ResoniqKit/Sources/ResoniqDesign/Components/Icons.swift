import SwiftUI

/// The product's own glyphs, with the paths of the mockups in design/screens.
public enum ResoniqIcon: CaseIterable, Sendable {
    case diagnose
    case measure
    case optimize
    case settings
    case chevronDown

    struct Layer {
        enum Paint {
            case fill
            case stroke(width: CGFloat)
        }

        let paint: Paint
        let path: Path
    }

    /// Side of the square the paths are drawn in, which is also the icon's size in points.
    var viewBox: CGFloat {
        switch self {
        case .diagnose, .measure, .optimize: 22
        case .settings: 18
        case .chevronDown: 14
        }
    }

    var layers: [Layer] {
        switch self {
        case .diagnose:
            // V3Diagnose tab bar: a speaker portrait in miniature.
            [Layer(paint: .fill, path: Path { p in
                p.move(to: CGPoint(x: 11, y: 1.5))
                p.addCurve(to: CGPoint(x: 16.5, y: 11), control1: CGPoint(x: 15, y: 4.5), control2: CGPoint(x: 16.5, y: 7.5))
                p.addCurve(to: CGPoint(x: 11, y: 20.5), control1: CGPoint(x: 16.5, y: 14.5), control2: CGPoint(x: 15, y: 17.5))
                p.addCurve(to: CGPoint(x: 5.5, y: 11), control1: CGPoint(x: 7, y: 17.5), control2: CGPoint(x: 5.5, y: 14.5))
                p.addCurve(to: CGPoint(x: 11, y: 1.5), control1: CGPoint(x: 5.5, y: 7.5), control2: CGPoint(x: 7, y: 4.5))
                p.closeSubpath()
            })]
        case .measure:
            // A response curve over its axis.
            [Layer(paint: .stroke(width: 1.8), path: Path { p in
                p.move(to: CGPoint(x: 2, y: 14))
                p.addCurve(to: CGPoint(x: 8, y: 6), control1: CGPoint(x: 5, y: 14), control2: CGPoint(x: 5, y: 6))
                p.addCurve(to: CGPoint(x: 13, y: 12), control1: CGPoint(x: 11, y: 6), control2: CGPoint(x: 11, y: 12))
                p.addCurve(to: CGPoint(x: 20, y: 9), control1: CGPoint(x: 15, y: 12), control2: CGPoint(x: 16, y: 9))
                p.move(to: CGPoint(x: 2, y: 19))
                p.addLine(to: CGPoint(x: 20, y: 19))
            })]
        case .optimize:
            // A room from above: two speakers and the seat.
            [Layer(paint: .stroke(width: 1.8), path: Path { p in
                p.addRoundedRect(in: CGRect(x: 3, y: 3, width: 16, height: 16), cornerSize: CGSize(width: 1.5, height: 1.5))
                p.addEllipse(in: CGRect(x: 9.2, y: 12.2, width: 3.6, height: 3.6))
                p.addRect(CGRect(x: 6.5, y: 6.5, width: 2, height: 2))
                p.addRect(CGRect(x: 13.5, y: 6.5, width: 2, height: 2))
            })]
        case .settings:
            // Two sliders.
            [Layer(paint: .stroke(width: 1.8), path: Path { p in
                p.move(to: CGPoint(x: 2, y: 5))
                p.addLine(to: CGPoint(x: 9, y: 5))
                p.move(to: CGPoint(x: 13, y: 5))
                p.addLine(to: CGPoint(x: 16, y: 5))
                p.move(to: CGPoint(x: 2, y: 13))
                p.addLine(to: CGPoint(x: 5, y: 13))
                p.move(to: CGPoint(x: 9, y: 13))
                p.addLine(to: CGPoint(x: 16, y: 13))
                p.addEllipse(in: CGRect(x: 9, y: 3, width: 4, height: 4))
                p.addEllipse(in: CGRect(x: 5, y: 11, width: 4, height: 4))
            })]
        case .chevronDown:
            [Layer(paint: .stroke(width: 2), path: Path { p in
                p.move(to: CGPoint(x: 3, y: 5))
                p.addLine(to: CGPoint(x: 7, y: 9))
                p.addLine(to: CGPoint(x: 11, y: 5))
            })]
        }
    }
}

/// Draws an icon in the current foreground style. Decorative: the control that holds it carries the label.
public struct ResoniqIconView: View {
    private let icon: ResoniqIcon
    @ScaledMetric private var side: CGFloat

    public init(_ icon: ResoniqIcon) {
        self.icon = icon
        _side = ScaledMetric(wrappedValue: icon.viewBox, relativeTo: .body)
    }

    public var body: some View {
        Canvas { [icon] context, size in
            let scale = size.width / icon.viewBox
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            for layer in icon.layers {
                let path = layer.path.applying(transform)
                switch layer.paint {
                case .fill:
                    context.fill(path, with: .foreground)
                case .stroke(let width):
                    context.stroke(
                        path,
                        with: .foreground,
                        style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
