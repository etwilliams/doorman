import AppKit
import SwiftUI

/// A panel that can take the keyboard without making Doorman the active app.
private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The one window: the picker, and Settings inside it. It is only ever hidden,
/// never closed, so it is ready for the next link.
///
/// It floats like Spotlight: a non-activating panel that takes the keyboard
/// while the app the link was clicked in stays active, so choosing hands
/// straight back to it. Settings is the exception, since its text fields need
/// Doorman's own Edit menu; opening it activates Doorman as a normal app.
@MainActor
final class PickerWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 460
    static let minHeight: CGFloat = 110
    static let maxHeight: CGFloat = 900

    let window: NSWindow
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            // Not resizable: the width is fixed and the height follows the content.
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // Doorman is usually not the active app while this is up, so it must
        // not vanish just because some other app is.
        panel.hidesOnDeactivate = false
        window = panel
        super.init()

        window.title = "Link Doorman"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Over full-screen apps too, on whichever Space the link was clicked in.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        let hosting = NSHostingView(rootView: RootView(model: model))
        // The window's height follows the content through fit(), not through
        // constraints, so the hosting view never fights the resize.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the panel without taking focus from the app in front, or, with
    /// `activating`, as a normal window of an active Doorman.
    func show(activating: Bool = false) {
        if !window.isVisible {
            model.refreshHandlerIcons()
            place()
        }
        // A hidden app's windows stay hidden; bring them back without activating.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if activating { NSApp.activate(ignoringOtherApps: true) }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
    }

    /// The window is normally only hidden, so revealing it is just showing it.
    func reveal() { show() }

    /// For Settings: its text fields need Doorman active, for the Edit menu.
    func activate() { show(activating: true) }

    func hide() {
        if window.isVisible {
            window.orderOut(nil)
            // If Settings made Doorman active, hand focus back to whatever the
            // user was doing. The floating picker never took it. NSApp.isActive
            // can't tell the two apart: it reads true whenever the panel has
            // the keyboard. Owning the menu bar is what being active means.
            if Self.ownsMenuBar { NSApp.hide(nil) }
        }
        model.quitIfTransient()
    }

    private static var ownsMenuBar: Bool {
        NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Where the setting in General says. Each way ends up wholly on one screen.
    private func place() {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let size = window.frame.size

        switch model.data.pickerPlacement {
        case .pointer:
            // Centered on the pointer, with the pointer over the title strip
            // rather than a handler, so a stray second click can't choose one.
            guard let area = pointerScreen?.visibleFrame else { return }
            setTop(NSPoint(x: pointer.x - size.width / 2, y: pointer.y + 14), within: area)
        case .window:
            // Over the window the link was clicked in; the screen if there is none.
            if let front = Self.frontWindowFrame(),
               let screen = NSScreen.screens.max(by: { overlap($0.frame, front) < overlap($1.frame, front) }) {
                setTop(centered(size, in: front), within: screen.visibleFrame)
            } else if let area = pointerScreen?.visibleFrame {
                setTop(centered(size, in: area), within: area)
            }
        case .screen:
            guard let area = pointerScreen?.visibleFrame else { return }
            setTop(centered(size, in: area), within: area)
        }
    }

    /// Centered across, a third of the way down: the eye lands high.
    private func centered(_ size: NSSize, in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - max(rect.height - size.height, 0) / 3)
    }

    /// Puts the window's top-left corner at `topLeft`, moved as needed to fit `area`.
    private func setTop(_ topLeft: NSPoint, within area: NSRect) {
        let size = window.frame.size
        let margin: CGFloat = 8
        let x = min(max(topLeft.x, area.minX + margin), area.maxX - size.width - margin)
        let top = max(min(topLeft.y, area.maxY - margin), area.minY + size.height + margin)
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: (top - size.height).rounded()))
    }

    private func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// The frontmost ordinary window of the active app, in screen coordinates.
    /// Window bounds and owners come from the window list, which needs no
    /// Screen Recording or Accessibility permission (only titles would).
    private static func frontWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.menuBarOwningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return nil }

        // Front to back; the first normal-layer window of that app, big enough
        // to be a document rather than a palette or tooltip.
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw),
                  bounds.width >= 200, bounds.height >= 150
            else { continue }
            // The window list measures from the top of the primary screen.
            return NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }
        return nil
    }

    func clearFocus() {
        window.makeFirstResponder(nil)
    }

    /// Lets the window follow the content instead of leaving dead space. The
    /// top edge stays put unless growing would run off the bottom of the
    /// screen, which it can when it opened low at the pointer; then it moves
    /// up. It never grows past the screen, and past that the content scrolls.
    func fit(contentHeight: CGFloat) {
        let frame = window.frame
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let limit = min(Self.maxHeight, area.height)
        let next = min(max(contentHeight.rounded(), Self.minHeight), limit)
        guard abs(frame.height - next) >= 1 else { return }
        let y = max(frame.maxY - next, area.minY)
        window.setFrame(NSRect(x: frame.minX, y: y, width: frame.width, height: next),
                        display: true, animate: false)
    }

    // MARK: NSWindowDelegate

    // Closing the picker should never quit the app while it lives in the menu
    // bar; it needs to stay resident to catch the next link.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.data.menuBar { hide() } else { NSApp.terminate(nil) }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window.level = .floating
        model.setPrivateMode(NSEvent.modifierFlags.contains(.option))
        // The user may have changed it in System Settings while we were away.
        model.refreshLoginItem()
    }

    // A modifier released while another app is in front never reaches us.
    func windowDidResignKey(_ notification: Notification) {
        model.setPrivateMode(false)
        // Clicked away from: stop floating, so the app clicked into can cover
        // it like any other window, while it waits with its links.
        window.level = .normal
    }
}
