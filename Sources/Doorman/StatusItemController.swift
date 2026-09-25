import AppKit

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The menu bar icon. While it is there Doorman stays running between links.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private var item: NSStatusItem?

    init(model: AppModel) {
        self.model = model
    }

    func sync() {
        guard model.data.menuBar else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = DoorGeometry.trayImage()
        item.button?.toolTip = "Doorman"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    // Rebuilt on every open, so Recent is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionMenuItem("Show Doorman") { [model] in model.window?.reveal() })

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if model.recent.isEmpty {
            let none = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            recentItem.isEnabled = false
        } else {
            for entry in model.recent {
                // Choosing one brings it back to the picker, even on a saved
                // domain, so it can be sent somewhere else.
                let link = ActionMenuItem(Self.label(for: entry.url)) { [model] in
                    model.enqueue(entry.url, ask: true)
                }
                if #available(macOS 14.4, *) {
                    link.subtitle = entry.handlerName
                } else {
                    link.toolTip = entry.handlerName
                }
                submenu.addItem(link)
            }
            submenu.addItem(.separator())
            submenu.addItem(ActionMenuItem("Clear Recent") { [model] in model.clearRecent() })
        }
        recentItem.submenu = submenu
        menu.addItem(recentItem)

        menu.addItem(ActionMenuItem("Settings…") { [model] in model.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Doorman", key: "q") { NSApp.terminate(nil) })
    }

    /// Host and path, without the scheme and query, cut to fit a menu.
    static func label(for url: String) -> String {
        var label = url
        if let parts = URLComponents(string: url), var host = parts.host {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let port = parts.port.map { ":\($0)" } ?? ""
            let path = parts.percentEncodedPath
            label = host + port + (path.isEmpty || path == "/" ? "" : path)
        }
        return label.count > 60 ? String(label.prefix(59)) + "…" : label
    }
}
