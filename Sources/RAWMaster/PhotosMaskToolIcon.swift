import SwiftUI
import RAWMasterCore

struct PhotosMaskToolIcon: View {
    enum Kind: CaseIterable {
        case subject, background, instance, brush, linear, radial, range, object, sky, water

        init(target: DevelopmentSemanticTarget) {
            switch target {
            case .subject: self = .subject
            case .background: self = .background
            case .instance: self = .instance
            case .brush: self = .brush
            case .object: self = .object
            case .sky: self = .sky
            case .water: self = .water
            }
        }

        init(layer: DevelopmentMaskLayerV3) {
            if let target = layer.semanticSnapshot?.target { self.init(target: target); return }
            switch layer.kind {
            case .linear: self = .linear
            case .radial: self = .radial
            case .range: self = .range
            case .subject: self = .subject
            }
        }

        var systemImage: String? {
            switch self {
            case .subject: return "person.crop.rectangle"
            case .instance: return "square.on.square.dashed"
            case .brush: return "paintbrush.pointed"
            case .object: return "viewfinder"
            case .sky: return "cloud"
            case .water: return "water.waves"
            case .background, .linear, .radial, .range: return nil
            }
        }
    }

    let kind: Kind

    var body: some View {
        Group {
            if let systemImage = kind.systemImage {
                Image(systemName: systemImage).resizable().scaledToFit()
            } else {
                PhotosMaskGeometryIcon(kind: kind).stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

private struct PhotosMaskGeometryIcon: Shape {
    let kind: PhotosMaskToolIcon.Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: x1, y: y1)); path.addLine(to: CGPoint(x: x2, y: y2))
        }
        switch kind {
        case .background:
            path.addRoundedRect(in: CGRect(x: 2, y: 2, width: 20, height: 20), cornerSize: CGSize(width: 2, height: 2))
            path.addEllipse(in: CGRect(x: 10, y: 6, width: 4, height: 4))
            path.move(to: CGPoint(x: 8, y: 19)); path.addLine(to: CGPoint(x: 8, y: 15))
            path.addQuadCurve(to: CGPoint(x: 16, y: 15), control: CGPoint(x: 12, y: 9))
            path.addLine(to: CGPoint(x: 16, y: 19))
            line(3, 8, 7, 4); line(3, 14, 7, 10)
            line(17, 10, 21, 6); line(17, 18, 21, 14)
        case .linear:
            path.addRoundedRect(in: CGRect(x: 2, y: 2, width: 20, height: 20), cornerSize: CGSize(width: 2, height: 2))
            line(2, 9, 22, 9); line(2, 15, 22, 15)
            for x: CGFloat in [6, 10, 14, 18] { line(x, 2, x, 9) }
            for x: CGFloat in [6, 18] { line(x, 9, x, 15) }
        case .radial:
            path.addEllipse(in: CGRect(x: 2, y: 4, width: 20, height: 16))
            path.addEllipse(in: CGRect(x: 7, y: 8, width: 10, height: 8))
            line(11, 12, 13, 12); line(12, 11, 12, 13)
        case .range:
            path.addRect(CGRect(x: 2, y: 7, width: 20, height: 10))
            for x: CGFloat in [7, 11, 15, 19] { line(x, 7, x, 17) }
            line(5, 3, 5, 7); line(19, 3, 19, 7)
            line(5, 17, 5, 21); line(19, 17, 19, 21)
        default:
            break
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
