import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var windowController: PickerWindowController!
    private var statusItem: StatusItemController!
    private var keyMonitor: Any?
    private var serviceProvider: ServiceProvider?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS delivers links as a GetURL Apple event. Registered before
        // launch finishes, so the link that launched the app is not missed.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // Also before launch finishes: a Services request can be what launched us.
        let provider = ServiceProvider(model: model)
        serviceProvider = provider
        NSApp.servicesProvider = provider
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.applyAppearance()
        NSApp.mainMenu = MainMenu.build(model: model)

        windowController = PickerWindowController(model: model)
        model.window = windowController

        statusItem = StatusItemController(model: model)
        model.onMenuBarChange = { [weak self] in self?.statusItem.sync() }
        statusItem.sync()

        installKeyMonitor()

        // `swift run Doorman https://…` passes links on argv.
        for argument in CommandLine.arguments.dropFirst() { model.enqueue(argument) }

        // A plain launch (Finder, Dock, Spotlight) shows the picker; one to
        // handle a link waits for it; one at login stays in the menu bar.
        let plainLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        model.start(showIdle: !model.packaged || (plainLaunch && !Self.launchedAsLoginItem()))
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        // The event names the process that asked for the link to be opened.
        let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        model.enqueue(url, source: sender > 0 ? SourceApps.bundleID(forPID: pid_t(sender)) : nil)
    }

    // Relaunching with no link at all (from the Dock, say) should show the picker.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.reveal()
        return false
    }

    // Staying open with no window is the whole point of a URL handler.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The picker has no text field to type into: keys are caught for the whole
    /// window so the number keys, Return and the filter all work at once.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.windowController.window else { return event }
            if event.type == .flagsChanged {
                self.model.setPrivateMode(event.modifierFlags.contains(.option))
                return event
            }
            // Settings has real text fields; typing in them is not a shortcut.
            let typing = event.window?.firstResponder is NSText
            if typing && event.keyCode != UInt16(kVK_Escape) { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }
}

@MainActor
enum MainMenu {
    static func build(model: AppModel) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Doorman")
        app.addItem(ActionMenuItem("About Doorman") { model.openSettings(tab: .about) })
        app.addItem(.separator())
        app.addItem(ActionMenuItem("Settings…", key: ",") { model.openSettings() })
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Doorman", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others",
                                 action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Doorman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        // Needed for ⌘C/⌘V/⌘A in the Settings fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
