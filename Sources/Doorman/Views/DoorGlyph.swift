import AppKit
import SwiftUI

/// The open-door mark, drawn from the same geometry as build/icon.svg: a frame
/// and a solid leaf swung open. The solid leaf is what keeps it reading as a
/// door rather than a bell at 16px.
enum DoorGeometry {
    // In a 120-unit box, after the SVG's translate(-4 -4).
    static let frame: [CGPoint] = [(36, 104), (36, 16), (92, 16), (92, 104)].map { CGPoint(x: $0.0 - 4, y: $0.1 - 4) }
    static let leaf: [CGPoint] = [(36, 16), (58, 26), (58, 112), (36, 104)].map { CGPoint(x: $0.0 - 4, y: $0.1 - 4) }
    static let box: CGFloat = 120
    static let stroke: CGFloat = 12

    static func path(_ points: [CGPoint], scale: CGFloat, offset: CGPoint = .zero, closed: Bool) -> Path {
        var path = Path()
        let mapped = points.map { CGPoint(x: offset.x + $0.x * scale, y: offset.y + $0.y * scale) }
        path.addLines(mapped)
        if closed { path.closeSubpath() }
        return path
    }

    /// The menu bar template image: pure black on transparent, which the system
    /// recolors for light and dark menu bars.
    static func trayImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale: CGFloat = 14 / box
            let offset = CGPoint(x: 1, y: 1)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(stroke * scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path(leaf, scale: scale, offset: offset, closed: true).cgPath)
            context.fillPath()
            context.addPath(path(leaf, scale: scale, offset: offset, closed: true).cgPath)
            context.addPath(path(frame, scale: scale, offset: offset, closed: false).cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The small mark next to the name in the title strip.
struct DoorMark: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let scale = size.width / DoorGeometry.box
            let style = StrokeStyle(lineWidth: DoorGeometry.stroke * scale, lineCap: .round, lineJoin: .round)
            let leaf = DoorGeometry.path(DoorGeometry.leaf, scale: scale, closed: true)
            context.fill(leaf, with: .color(color))
            context.stroke(leaf, with: .color(color), style: style)
            context.stroke(DoorGeometry.path(DoorGeometry.frame, scale: scale, closed: false),
                           with: .color(color), style: style)
        }
    }
}

/// The app icon as the About tab shows it, drawn so it matches in development
/// builds too, where the bundle has no icon.
struct AppIconView: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 512
            let rect = CGRect(x: 26 * unit, y: 26 * unit, width: 460 * unit, height: 460 * unit)
            context.fill(Path(roundedRect: rect, cornerRadius: 104 * unit, style: .continuous),
                         with: .color(Color(hex: "#2563eb") ?? .blue))

            func points(_ list: [(CGFloat, CGFloat)]) -> [CGPoint] { list.map { CGPoint(x: $0.0, y: $0.1) } }
            let style = StrokeStyle(lineWidth: 28 * unit, lineCap: .round, lineJoin: .round)
            let frame = DoorGeometry.path(points([(195, 360), (195, 131), (341, 131), (341, 360)]),
                                          scale: unit, closed: false)
            let leaf = DoorGeometry.path(points([(195, 131), (252, 157), (252, 381), (195, 360)]),
                                         scale: unit, closed: true)
            context.fill(leaf, with: .color(.white))
            context.stroke(leaf, with: .color(.white), style: style)
            context.stroke(frame, with: .color(.white), style: style)
        }
    }
}
