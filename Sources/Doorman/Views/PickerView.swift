import AppKit
import DoormanCore
import SwiftUI

struct PickerView: View {
    @Bindable var model: AppModel
    @FocusState private var urlFocused: Bool

    private var idle: Bool { model.url == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !idle {
                    Hairline().padding(.bottom, 10)
                    if !model.data.handlers.isEmpty { rememberRow }
                    if !model.filter.isEmpty { filterChip }
                    handlers
                }
                footer
            }
            .padding(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
            .onHeightChange { model.requestHeight(28 + $0) }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top)
        // Kept outside the scroll view: one that reaches under the title bar
        // gets an automatic content inset for it on top of this one.
        .padding(.top, 28)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if !idle { LinkIcon(image: model.linkIcon) }
                Text(model.url.flatMap { URLComponents(string: $0)?.hostWithPort } ?? "No link waiting")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(-0.15)
                    .lineLimit(1)
            }

            if let title = model.pageTitle, !model.editingURL {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                    .transition(.opacity)
            }

            if model.editingURL {
                TextField("", text: $model.urlDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                        model.urlInvalid ? Theme.danger : (urlFocused ? Theme.accent : Theme.line)))
                    .focused($urlFocused)
                    .onSubmit { model.commitEdit() }
                    .onAppear { urlFocused = true }
            } else {
                Text(model.url.map(Self.breakAnywhere) ?? "Links opened elsewhere will show up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.startEdit() }
                    .help(idle ? "" : "Double-click or ⌘L to edit")
            }

            if model.source != nil || model.pending > 0 {
                HStack(spacing: 5) {
                    if let source = model.source { SourceBadge(info: model.sourceInfo(source)) }
                    if model.pending > 0 {
                        Badge { Text("\(model.pending) more link\(model.pending == 1 ? "" : "s") queued") }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(EdgeInsets(top: 2, leading: 2, bottom: idle ? 2 : 12, trailing: 2))
    }

    /// Lets a URL wrap at any character, as `word-break: break-all` did, rather
    /// than only at the few punctuation marks a line breaker likes.
    private static func breakAnywhere(_ url: String) -> String {
        url.map(String.init).joined(separator: "\u{200B}")
    }

    // MARK: Remember

    private var rememberRow: some View {
        RememberRow(model: model)
            .padding(.bottom, 9)
    }

    private var filterChip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(model.filter)
                .padding(.vertical, 1)
                .padding(.horizontal, 7)
                .background(Theme.row, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
            Text("esc to clear")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    // MARK: Handlers

    @ViewBuilder
    private var handlers: some View {
        let shown = model.visibleHandlers
        if shown.isEmpty {
            Text(model.data.handlers.isEmpty
                 ? "No handlers configured yet. Open Settings to add one."
                 : "No handler matches “\(model.filter)”.")
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            VStack(spacing: 5) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, handler in
                    HandlerRow(model: model, handler: handler, index: index)
                }
            }
        }
        if let error = model.launchError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
                .padding(.top, 8)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if !idle { Hairline().padding(.bottom, 10) }
            HStack(spacing: 6) {
                if !idle {
                    Button("Copy") { model.copyURL() }
                    Button("Skip") { model.skip() }
                }
                Spacer()
                Button("Settings") { model.show(.settings) }
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.top, idle ? 6 : 12)
    }
}

/// The site's icon beside its host. A globe holds the place until the icon
/// loads, or for good when the site has none, so the host never shifts.
private struct LinkIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .transition(.opacity)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 16, height: 16)
        .animation(.easeOut(duration: 0.15), value: image != nil)
    }
}

private struct RememberRow: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Toggle(isOn: $model.remember) {
                    (Text("Always open ")
                        + Text(model.domain ?? "").fontWeight(.semibold).foregroundColor(Theme.fg)
                        + Text(" with my choice"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                .focusable(false)
                Spacer(minLength: 4)
                Text("or hold ⇧ · ⌥ private")
                    .font(.system(size: 10.5))
                    .opacity(0.75)
                    .fixedSize()
            }
            // Only when the link says where it came from.
            if let source = model.source {
                Toggle(isOn: $model.rememberSource) {
                    (Text("Always open links from ")
                        + Text(model.sourceInfo(source).name).fontWeight(.semibold).foregroundColor(Theme.fg)
                        + Text(" with my choice"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                .focusable(false)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(hovering ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Theme.line : .clear))
        .onHover { hovering = $0 }
    }
}

/// A small capsule of muted text under the link.
private struct Badge<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(Theme.row, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
    }
}

/// Which app the link came from.
private struct SourceBadge: View {
    let info: SourceAppInfo

    var body: some View {
        Badge {
            HStack(spacing: 4) {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 12, height: 12)
                }
                Text("from \(info.name)").lineLimit(1)
            }
        }
    }
}

private struct HandlerRow: View {
    let model: AppModel
    let handler: Handler
    let index: Int

    var body: some View {
        let capable = model.privateCapable(handler)
        let privateMode = model.privateMode

        Button {
            // Shift is a one-shot version of the checkbox, for when you already know.
            let flags = NSEvent.modifierFlags
            model.choose(handler.id, remember: flags.contains(.shift) || model.remember,
                         privately: flags.contains(.option))
        } label: {
            HStack(spacing: 10) {
                HandlerIcon(artwork: model.artwork(for: handler), color: handler.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(handler.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !handler.subtitle.isEmpty {
                        Text(handler.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // Holding ⌥: rows that can open privately say so, the rest step back.
                if privateMode && capable {
                    Text("Private")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 6)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                } else if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .frame(minWidth: 17)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .focusable(false)
        .opacity(privateMode && !capable ? 0.4 : 1)
    }
}

extension URLComponents {
    /// The host as a browser's location.host shows it, port included.
    var hostWithPort: String? {
        guard let host else { return nil }
        return host + (port.map { ":\($0)" } ?? "")
    }
}
