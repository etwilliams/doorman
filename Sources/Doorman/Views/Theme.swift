import AppKit
import SwiftUI

/// The Electron build's palette, light and dark, over the window's vibrancy.
enum Theme {
    static let fg = dynamic(light: hex(0x16181d), dark: hex(0xf2f3f5))
    static let muted = dynamic(light: hex(0x6b7280), dark: hex(0x9aa1ad))
    static let line = dynamic(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.12))
    static let row = dynamic(light: NSColor(white: 1, alpha: 0.55), dark: NSColor(white: 1, alpha: 0.07))
    static let rowHover = dynamic(light: NSColor(white: 1, alpha: 0.95), dark: NSColor(white: 1, alpha: 0.14))
    static let field = dynamic(light: NSColor(white: 1, alpha: 0.7), dark: NSColor(white: 0, alpha: 0.25))
    static let accent = dynamic(light: hex(0x2563eb), dark: hex(0x6ea8ff))
    static let danger = Color(red: 0.86, green: 0.15, blue: 0.15)
    static let radius: CGFloat = 10

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1)
    }
}

extension Color {
    /// Parses #rgb, #rrggbb or #rrggbbaa. Handler colors are free text in
    /// handlers.json, so anything else is nil.
    init?(hex string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255,
                  opacity: hasAlpha ? Double(value & 0xff) / 255 : 1)
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func byte(_ component: CGFloat) -> Int { Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.redComponent), byte(color.greenComponent),
                      byte(color.blueComponent))
    }
}

struct Dot: View {
    var color: String

    var body: some View {
        Circle()
            .fill(Color(hex: color) ?? Color(nsColor: Theme.hex(0x6b7280)))
            .frame(width: 9, height: 9)
    }
}

/// A handler's face: its profile photo in a ring of its color with a small
/// badge for the browser, or the browser's own icon with a dot of its color,
/// or, when neither can be found, just the dot.
struct HandlerIcon: View {
    let artwork: HandlerArtwork
    let color: String
    var size: CGFloat = 26

    private var tint: Color { Color(hex: color) ?? Color(nsColor: Theme.hex(0x6b7280)) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let photo = artwork.photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                if let app = artwork.app {
                    Image(nsImage: app)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size * 0.52, height: size * 0.52)
                        .offset(x: size * 0.14, y: size * 0.14)
                }
            } else if let app = artwork.app {
                Image(nsImage: app)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                // Several profiles of one browser share its icon; the dot tells them apart.
                Circle()
                    .fill(tint)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: size * 0.06, y: size * 0.06)
            } else {
                Dot(color: color)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A full-width row button: a handler in the picker.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Theme.rowHover : Theme.row, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A quiet text button that only shows its edges on hover.
struct GhostButtonStyle: ButtonStyle {
    var bordered = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, bordered: bordered, small: small)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        let bordered: Bool
        let small: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: small ? 11.5 : 13))
                .foregroundStyle(hovering && enabled ? Theme.fg : Theme.muted)
                .padding(.vertical, small ? 1 : 4)
                .padding(.horizontal, small ? 8 : 9)
                .background(hovering && enabled ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hovering || bordered ? Theme.line : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// A 24pt square glyph button: reorder, forget.
struct IconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(hovering ? Theme.fg : Theme.muted)
                .background(hovering ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovering ? Theme.line : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The hairline dividing sections, as the web build's borders did.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

/// A small muted explanation, optionally with markdown.
struct Note: View {
    var text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Reports this view's height as it lays out.
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: action)
    }
}
