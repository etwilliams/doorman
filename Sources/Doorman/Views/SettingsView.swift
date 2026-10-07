import AppKit
import DoormanCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var fixedHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        // The title and tabs stay put and only the active panel scrolls, so a
        // long domain list never pushes the tabs out of reach.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Settings").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { model.show(.picker) }.buttonStyle(GhostButtonStyle())
                }
                .padding(.bottom, 8)
                Hairline()

                Picker("", selection: Binding(get: { model.tab }, set: { model.setTab($0) })) {
                    ForEach(AppModel.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, 10)
            }
            .onHeightChange { fixedHeight = $0; report() }

            ScrollView {
                panel
                    .padding(.bottom, 1)
                    .onHeightChange { panelHeight = $0; report() }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
        }
        .padding(EdgeInsets(top: 28, leading: 16, bottom: 14, trailing: 16))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func report() {
        model.requestHeight(28 + fixedHeight + panelHeight + 14)
    }

    @ViewBuilder
    private var panel: some View {
        switch model.tab {
        case .handlers: HandlersPanel(model: model)
        case .domains: DomainsPanel(model: model)
        case .apps: AppsPanel(model: model)
        case .general: GeneralPanel(model: model)
        case .about: AboutPanel(model: model)
        }
    }
}

/// A row of buttons closes a panel, set off from the settings above it by the
/// same divider the picker's footer uses.
private struct Actions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline().padding(.bottom, 10)
            HStack(spacing: 6) { content }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

// MARK: - Handlers

private struct HandlersPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 7) {
                ForEach(Array(model.draft.enumerated()), id: \.element.id) { index, handler in
                    HandlerCard(model: model, handler: binding(for: handler), index: index)
                }
            }
            .padding(.vertical, 10)

            Actions {
                Button("Add handler") { model.addHandler() }
                Button("Re-detect browsers") { Task { await model.rediscover() } }
            }

            // The {url} hint only means anything next to an open Arguments field.
            if model.openHandler != nil {
                Note("Use `{url}` in an argument to mark where the link goes. If no argument contains it, the link is appended last.")
            }
        }
    }

    // Looked up by id, so a card being removed never reads past the end.
    private func binding(for handler: Handler) -> Binding<Handler> {
        Binding(
            get: { model.draft.first { $0.id == handler.id } ?? handler },
            set: { next in
                if let index = model.draft.firstIndex(where: { $0.id == handler.id }) { model.draft[index] = next }
            }
        )
    }
}

private struct HandlerCard: View {
    let model: AppModel
    @Binding var handler: Handler
    let index: Int
    @State private var hovering = false

    private var open: Bool { model.openHandler == handler.id }

    var body: some View {
        VStack(spacing: 0) {
            head
            if open { details }
        }
        .background(Theme.row, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // Enough to identify and reorder without opening. Reordering changes which
    // number key opens what, so it stays reachable collapsed.
    private var head: some View {
        HStack(spacing: 9) {
            HandlerIcon(artwork: model.artwork(for: handler), color: handler.color, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(handler.name).fontWeight(.medium).lineLimit(1)
                if !handler.subtitle.isEmpty {
                    Text(handler.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            IconButton(systemImage: "arrow.up", help: "Move up") { model.moveDraft(index, by: -1) }
            IconButton(systemImage: "arrow.down", help: "Move down") { model.moveDraft(index, by: 1) }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .rotationEffect(.degrees(open ? 180 : 0))
                .animation(.easeOut(duration: 0.12), value: open)
                .frame(width: 12)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(hovering ? Theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openHandler = open ? nil : handler.id }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Name")
            HStack(spacing: 6) {
                ColorSwatch(hex: $handler.color)
                SettingsField(placeholder: "Chrome — Work", text: $handler.name)
            }

            FieldLabel("Subtitle")
            SettingsField(text: $handler.subtitle)

            FieldLabel("Command")
            SettingsField(text: $handler.command)

            FieldLabel("Arguments (one per line)")
            ArgumentsEditor(text: Binding(
                get: { handler.args.joined(separator: "\n") },
                set: { handler.args = $0.components(separatedBy: "\n") }
            ))

            RemoveButton { model.removeDraft(handler.id) }
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
        .overlay(alignment: .top) { Hairline() }
    }
}

/// A square swatch that opens the system color panel. SwiftUI's ColorPicker
/// draws a wide capsule whatever frame it is given, which ran under the name
/// field beside it.
private struct ColorSwatch: View {
    @Binding var hex: String

    var body: some View {
        Button {
            ColorPanelBridge.shared.edit(hex) { hex = $0 }
        } label: {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(hex: hex) ?? Color(nsColor: Theme.hex(0x6b7280)))
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose a color")
    }
}

/// Routes the shared NSColorPanel to whichever swatch opened it last.
@MainActor
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((String) -> Void)?

    func edit(_ hex: String, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first, so seeding the panel's color doesn't write back to the
        // previous swatch.
        self.onChange = nil
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(Color(hex: hex) ?? Color(nsColor: Theme.hex(0x6b7280)))
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color).hexString)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5))
            .kerning(0.4)
            .foregroundStyle(Theme.muted)
    }
}

private struct SettingsField: View {
    var placeholder = ""
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accent : Theme.line))
    }
}

private struct ArgumentsEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let lines = max(text.components(separatedBy: "\n").count, 2)
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .focused($focused)
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
            .frame(height: CGFloat(lines) * 14 + 12)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accent : Theme.line))
    }
}

private struct RemoveButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button("Remove handler", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(hovering ? Color(red: 0.88, green: 0.42, blue: 0.42) : Theme.muted)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovering ? Theme.line : .clear))
            .onHover { hovering = $0 }
    }
}

// MARK: - Domains

private struct DomainsPanel: View {
    let model: AppModel

    var body: some View {
        let domains = model.data.rules.keys.sorted()
        if domains.isEmpty {
            Note("No saved domains yet. Tick **Always open…** in the picker, or hold `⇧` while choosing, and links on that domain will skip the picker from then on.")
        } else {
            VStack(spacing: 4) {
                ForEach(domains, id: \.self) { domain in
                    DomainRow(model: model, domain: domain)
                }
            }
        }
    }
}

private struct DomainRow: View {
    let model: AppModel
    let domain: String

    var body: some View {
        let handler = model.data.handlers.first { $0.id == model.data.rules[domain] }
        HStack(spacing: 8) {
            // Until the icon has been fetched (or when the site has none) the
            // slot stays empty, so domains still line up.
            Group {
                if let icon = model.favicon(for: domain) {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)

            Text(domain).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            Dot(color: handler?.color ?? "#00000000")
            Text(handler.map { "→ \($0.name)" } ?? "→ (handler removed)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(systemImage: "xmark", help: "Forget \(domain)") { model.removeRule(domain) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

// MARK: - Apps

private struct AppsPanel: View {
    let model: AppModel

    var body: some View {
        let apps = model.data.sourceRules.keys.sorted {
            model.sourceInfo($0).name.localizedCaseInsensitiveCompare(model.sourceInfo($1).name) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 0) {
            if apps.isEmpty {
                Note("No saved apps yet. When a link comes from an app, the picker offers **Always open links from…** for it. Or add one here.")
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 4) {
                    ForEach(apps, id: \.self) { bundleID in
                        AppRuleRow(model: model, bundleID: bundleID)
                    }
                }
                .padding(.bottom, 10)
            }

            Actions {
                Button("Add app…") { model.addSourceApp() }
                    .disabled(model.data.handlers.isEmpty)
            }
            Note("A saved domain wins over a saved app: its links open where the domain says, whichever app they came from.")
        }
    }
}

private struct AppRuleRow: View {
    let model: AppModel
    let bundleID: String

    var body: some View {
        let info = model.sourceInfo(bundleID)
        HStack(spacing: 8) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 16, height: 16)

            Text(info.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(bundleID)
            Spacer(minLength: 4)
            Picker("", selection: Binding(
                get: { model.data.sourceRules[bundleID] ?? "" },
                set: { model.setSourceRule(bundleID, handlerId: $0) }
            )) {
                ForEach(model.data.handlers) { handler in
                    Text(handler.name).tag(handler.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            IconButton(systemImage: "xmark", help: "Forget \(info.name)") { model.removeSourceRule(bundleID) }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

// MARK: - General

private struct GeneralPanel: View {
    let model: AppModel

    var body: some View {
        let login = model.loginItem
        let menuBar = model.data.menuBar
        // Without the menu bar there is nothing for a login launch to keep running.
        let loginDisabled = !login.available || !menuBar

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Appearance").foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Picker("", selection: Binding(get: { model.data.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Text("Open the picker").foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Picker("", selection: Binding(get: { model.data.pickerPlacement },
                                              set: { model.setPickerPlacement($0) })) {
                    Text("Centered on the front window").tag(PickerPlacement.window)
                    Text("Centered on the screen").tag(PickerPlacement.screen)
                    Text("At the pointer").tag(PickerPlacement.pointer)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 12)

            Check("Keep Link Doorman in the menu bar", isOn: menuBar) { model.setMenuBar($0) }
            Caption { Note("Off: Link Doorman quits when you close this window, and starts again the next time you click a link.") }

            Check("Open Link Doorman at login", isOn: login.enabled) { model.setOpenAtLogin($0) }
                .disabled(loginDisabled)
                .opacity(loginDisabled ? 0.55 : 1)
            Caption { loginNote(login: login, menuBar: menuBar) }

            HStack(spacing: 8) {
                Check("Ring a doorbell when a link needs a choice", isOn: model.data.doorbell) { model.setDoorbell($0) }
                Spacer(minLength: 0)
                Button("Play") { model.previewDoorbell() }
                    .buttonStyle(GhostButtonStyle(bordered: true, small: true))
            }
            Caption { Note("Links on a saved domain go straight through without a sound.") }

            Check("Show page titles in the picker", isOn: model.data.pageTitles) { model.setPageTitles($0) }
            Caption {
                Note("Link Doorman loads each link's page, without cookies, before you choose. A one-time link, such as a sign-in or password reset link, can be used up by that and then fail in your browser.")
            }

            Check("Also copy the URL to the clipboard when opening", isOn: model.data.copyOnOpen) {
                model.setCopyOnOpen($0)
            }
            .padding(.bottom, 10)

            Actions {
                Button("Register as default browser") { Task { await model.setDefaultBrowser() } }
                Button("Show config file") { model.revealConfig() }
            }
            if let note = model.defaultNote { Note(LocalizedStringKey(note)) }
        }
    }

    @ViewBuilder
    private func loginNote(login: LoginItemState, menuBar: Bool) -> some View {
        if !login.available {
            Note("Only available in the installed app.")
        } else if !menuBar {
            Note("Needs the menu bar icon: without it, Link Doorman quits when it has nothing to show.")
        } else if login.needsApproval {
            HStack(spacing: 0) {
                Note("macOS needs you to allow it in ").fixedSize()
                Button("Login Items") { model.openLoginItems() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                Note(".")
            }
        } else {
            Note("Link Doorman works without this: macOS starts it when you click your first link, which just takes a moment longer.")
        }
    }
}

private struct Check: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    init(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) {
        self.title = title
        self.isOn = isOn
        self.set = set
    }

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.checkbox)
            .foregroundStyle(Theme.muted)
    }
}

/// Explains the toggle directly above it, indented to read as its caption.
private struct Caption<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.leading, 20)
            .padding(.top, 2)
            .padding(.bottom, 12)
    }
}

// MARK: - About

private struct AboutPanel: View {
    let model: AppModel

    var body: some View {
        let about = model.about
        let domains = model.data.rules.count
        let apps = model.data.sourceRules.count
        let handlers = model.data.handlers.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Link Doorman").font(.system(size: 16, weight: .semibold)).kerning(-0.16)
                    Text(about.map { "Version \($0.version)\($0.packaged ? "" : " (development)")" } ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                    Text("Pick which browser and profile opens every link.")
                        .font(.system(size: 12))
                        .padding(.top, 3)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 2, bottom: 14, trailing: 2))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Default browser").foregroundStyle(Theme.muted)
                    Text(about.map { $0.isDefault ? "Yes" : "No — set it under General" } ?? "")
                }
                GridRow {
                    Text("Saved rules").foregroundStyle(Theme.muted)
                    Text("\(domains) domain\(domains == 1 ? "" : "s"), \(apps) app\(apps == 1 ? "" : "s") " +
                         "across \(handlers) handler\(handlers == 1 ? "" : "s")").monospacedDigit()
                }
                GridRow {
                    Text("Settings folder").foregroundStyle(Theme.muted)
                    Text(about?.folder ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(about?.folder ?? "")
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .padding(.bottom, 12)

            Actions {
                Button("Show settings folder") { model.revealConfig() }
            }
        }
    }
}
