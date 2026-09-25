import AppKit
import DoormanCore
import Observation
import ServiceManagement

struct RecentLink: Equatable {
    let url: String
    let handlerName: String
    let at: Date
}

struct LoginItemState: Equatable {
    var available = false
    var enabled = false
    var needsApproval = false
}

struct AboutInfo: Equatable {
    var version: String
    var folder: String
    var isDefault: Bool
    var packaged: Bool
}

/// All of Doorman's state: the queue of links waiting for a decision, the
/// saved config, and what the window is showing.
@MainActor
@Observable
final class AppModel {
    enum Screen { case picker, settings }

    enum Tab: String, CaseIterable, Identifiable {
        case handlers, domains, apps, general, about
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    static let recentLimit = 10
    // A burst of links (a script, an "open all" in some app) rings once, not per link.
    static let doorbellGap: TimeInterval = 1.5

    // MARK: Link state

    /// Links waiting for a decision. The front of the queue is what the window shows.
    private(set) var queue: [String] = []
    /// Queued URLs that must show the picker even though a saved rule covers
    /// them: reopening a recent link is asking where it should go this time.
    @ObservationIgnored private var forceAsk = Set<String>()
    /// The bundle id of the app each queued link came from, when known.
    private var sourceByURL: [String: String] = [:]
    /// The last few links opened, newest first, for the menu bar's Recent
    /// submenu. Kept in memory only: URLs carry tokens and personal data, and
    /// none of that belongs on disk.
    private(set) var recent: [RecentLink] = []

    private(set) var data: ConfigData
    private(set) var faviconVersions: [String: Int] = [:]
    private(set) var loginItem = LoginItemState()
    /// Bumped when handler artwork should be looked up again.
    private(set) var handlerIconsVersion = 0
    /// The title of the page on screen, once loaded, when titles are on.
    private(set) var pageTitle: String?
    /// The site icon for the link on screen, once it has loaded.
    private(set) var linkIcon: NSImage?

    // MARK: Window state

    private(set) var screen: Screen = .picker
    private(set) var tab: Tab = .handlers
    /// Settings edits a copy, so an argument line being typed does not vanish
    /// under the cursor; it is cleaned up only on the way to disk.
    var draft: [Handler] = [] { didSet { if draft != oldValue { saveDraft() } } }
    var openHandler: String?
    /// Typed in the picker to narrow the handler list. There is no text field
    /// for it: keys are caught at the window so the digit shortcuts keep working.
    private(set) var filter = ""
    /// While ⌥ is held, choosing a handler opens a private window.
    private(set) var privateMode = false
    var remember = false
    /// The picker's second checkbox: save a rule for the app the link came from.
    var rememberSource = false
    private(set) var editingURL = false
    var urlDraft = "" { didSet { urlInvalid = false } }
    private(set) var urlInvalid = false
    private(set) var launchError: String?
    private(set) var about: AboutInfo?
    private(set) var defaultNote: String?

    // MARK: Plumbing

    @ObservationIgnored let config: Config
    @ObservationIgnored let supportDirectory: URL
    @ObservationIgnored let packaged: Bool
    @ObservationIgnored private var favicons: Favicons!
    @ObservationIgnored weak var window: PickerWindowController?
    @ObservationIgnored var onMenuBarChange: (() -> Void)?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var lastDoorbell = Date.distantPast
    @ObservationIgnored private var doorbellPending = false
    @ObservationIgnored private var shownURL: String?
    @ObservationIgnored private var images: [String: (version: Int, image: NSImage?)] = [:]
    @ObservationIgnored private var linkIconTask: Task<Void, Never>?
    @ObservationIgnored private var pageTitleTask: Task<Void, Never>?
    @ObservationIgnored private let pageTitles = PageTitles()
    @ObservationIgnored private let handlerIcons = HandlerIcons()

    init() {
        // DOORMAN_SUPPORT_DIR points development runs at a scratch config.
        let support = ProcessInfo.processInfo.environment["DOORMAN_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Doorman")
        supportDirectory = support
        // Only a real app bundle can be a login item or the default browser.
        packaged = Bundle.main.bundleURL.pathExtension == "app"
        config = Config(file: support.appendingPathComponent("handlers.json"))
        data = config.data
        favicons = Favicons(
            dir: support.appendingPathComponent("favicons"),
            isWanted: { [weak self] domain in self?.data.rules[domain] != nil },
            onChange: { [weak self] in self?.refreshFavicons() }
        )
        refreshFavicons()
        loginItem = currentLoginItem()
    }

    // MARK: Derived

    var url: String? { queue.first }
    var domain: String? { url.flatMap { Rules.domain(forHost: Self.host(of: $0)) } }
    var pending: Int { max(queue.count - 1, 0) }
    /// The bundle id of the app the link on screen came from.
    var source: String? { url.flatMap { sourceByURL[$0] } }

    func sourceInfo(_ bundleID: String) -> SourceAppInfo { SourceApps.info(for: bundleID) }

    /// The handlers the picker shows, in order; the number keys index into this.
    var visibleHandlers: [Handler] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return data.handlers }
        return data.handlers.filter { "\($0.name) \($0.subtitle)".lowercased().contains(needle) }
    }

    func privateCapable(_ handler: Handler) -> Bool { handler.privateModeArgs != nil }

    func artwork(for handler: Handler) -> HandlerArtwork {
        _ = handlerIconsVersion // re-read after refreshHandlerIcons()
        return handlerIcons.artwork(for: handler)
    }

    /// Picks up browsers installed or profile photos changed since last time.
    func refreshHandlerIcons() {
        handlerIcons.reset()
        handlerIconsVersion += 1
    }

    static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func host(of url: String) -> String? {
        URL(string: url)?.host?.lowercased()
    }

    // MARK: Lifecycle

    /// Called once the app has finished launching. Links that arrived before
    /// then were only queued.
    func start(showIdle: Bool) {
        ready = true
        // Route the ones a saved domain covers before deciding whether there is
        // anything to ask about.
        drain()
        stateChanged()
        if !queue.isEmpty { doorbellPending = true }
        if doorbellPending {
            doorbellPending = false
            ringDoorbell()
        }
        if !queue.isEmpty || showIdle {
            window?.show()
        } else {
            // Launched with nothing to show. A link may still be on its way in
            // from LaunchServices; if none comes, a transient Doorman has no
            // reason to stay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.queue.isEmpty, self.window?.isVisible != true else { return }
                self.quitIfTransient()
            }
        }
    }

    func enqueue(_ url: String, ask: Bool = false, source: String? = nil) {
        guard Self.isWebURL(url) else { return }
        if ask { forceAsk.insert(url) }
        if queue.contains(url) {
            if ready { window?.show() }
            return
        }
        if let source { sourceByURL[url] = source }
        queue.append(url)

        // Before launch finishes, start() drains what piled up.
        guard ready else { return }

        drain()
        stateChanged()
        if queue.contains(url) && !ask { ringDoorbell() }
        if !queue.isEmpty { window?.show() }
    }

    /// Launches every queued URL that a saved domain or app already covers, so
    /// the picker only appears for links the user has not decided about yet.
    private func drain() {
        for index in queue.indices.reversed() {
            let url = queue[index]
            if forceAsk.contains(url) { continue }
            // A failed launch falls through to the picker rather than dropping the link.
            if let id = config.handlerId(forHost: Self.host(of: url), source: sourceByURL[url]),
               launch(id, url) == nil {
                queue.remove(at: index)
                sourceByURL[url] = nil
            }
        }
    }

    private func dropFront() {
        guard !queue.isEmpty else { return }
        let url = queue.removeFirst()
        forceAsk.remove(url)
        sourceByURL[url] = nil
    }

    /// Returns nil on success, or an error to show.
    private func launch(_ handlerId: String, _ url: String, privately: Bool = false) -> String? {
        guard let handler = data.handlers.first(where: { $0.id == handlerId }), Self.isWebURL(url) else {
            return "Unknown handler or URL"
        }
        guard let args = handler.launchArguments(for: url, privately: privately) else {
            return "\(handler.name) has no private window mode"
        }
        if let error = Launcher.spawn(handler.command, args) { return error }

        if data.copyOnOpen { copyToPasteboard(url) }
        // A private window is a request not to leave a trail, so it stays out of Recent.
        if !privately { addRecent(url, handler) }
        return nil
    }

    private func addRecent(_ url: String, _ handler: Handler) {
        recent.removeAll { $0.url == url }
        recent.insert(RecentLink(url: url, handlerName: handler.name, at: Date()), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    func clearRecent() { recent.removeAll() }

    /// Every config or queue change ends here, so this is where the icon cache
    /// catches up with the saved domains, and a new link on screen starts from
    /// a clean slate.
    private func stateChanged() {
        data = config.data
        favicons.sync(Array(data.rules.keys))
        if url != shownURL {
            shownURL = url
            filter = ""
            endEdit()
            launchError = nil
            // Both checkboxes are about this link's domain and app; the next
            // link may have neither in common.
            remember = false
            rememberSource = false
            loadLinkIcon()
            loadPageTitle()
        }
        loginItem = currentLoginItem()
    }

    private func loadPageTitle() {
        pageTitleTask?.cancel()
        pageTitle = nil
        guard data.pageTitles, let url else { return }
        pageTitleTask = Task { [weak self] in
            guard let title = await self?.pageTitles.title(for: url) else { return }
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.pageTitle = title
        }
    }

    private func loadLinkIcon() {
        linkIconTask?.cancel()
        linkIcon = nil
        guard let url else { return }
        linkIconTask = Task { [weak self] in
            guard let image = await self?.favicons.icon(forLink: url) else { return }
            // The picker may have moved on to another link while it loaded.
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.linkIcon = image
        }
    }

    private func refreshFavicons() {
        faviconVersions = favicons.list()
    }

    private func advance() {
        dropFront()
        stateChanged()
        if queue.isEmpty { window?.hide() }
    }

    /// Without a menu bar icon there is nothing to return to, so staying
    /// resident would leave the app running invisibly with no way to reach or
    /// stop it. The system relaunches it on the next link anyway.
    func quitIfTransient() {
        if !data.menuBar { NSApp.terminate(nil) }
    }

    // MARK: Doorbell

    /// Rings when a link needs a decision, i.e. the picker is about to ask.
    /// Links a saved domain routes never get here, and neither does reopening a
    /// Recent link: that is the user's own doing, not a visitor at the door.
    private func ringDoorbell() {
        guard data.doorbell else { return }
        guard ready else {
            doorbellPending = true
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastDoorbell) >= Self.doorbellGap else { return }
        lastDoorbell = now
        Doorbell.ring()
    }

    func previewDoorbell() { Doorbell.ring() }

    // MARK: Picker actions

    func choose(_ handlerId: String, remember: Bool, privately: Bool) {
        // A handler with no private mode ignores ⌥ rather than opening
        // normally, which would be the opposite of what was asked for.
        guard let handler = data.handlers.first(where: { $0.id == handlerId }), let url else { return }
        if privately && !privateCapable(handler) { return }
        // A private open is a one-off by nature, so it never saves a rule.
        let saveDomain = remember && !privately
        let saveSource = rememberSource && !privately ? source : nil
        self.remember = false
        rememberSource = false

        if let error = launch(handlerId, url, privately: privately) {
            launchError = error
            NSSound.beep()
            return
        }

        if saveDomain { config.setRule(host: Self.host(of: url), handlerId: handlerId) }
        if let saveSource { config.setSourceRule(bundleID: saveSource, handlerId: handlerId) }
        dropFront()
        // A new rule may cover links already waiting behind this one.
        if saveDomain || saveSource != nil { drain() }
        stateChanged()
        if queue.isEmpty { window?.hide() }
    }

    func skip() { advance() }

    /// Drops every queued link.
    func dismiss() {
        queue.removeAll()
        forceAsk.removeAll()
        sourceByURL.removeAll()
        stateChanged()
        window?.hide()
    }

    func copyURL() {
        if let url { copyToPasteboard(url) }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func setPrivateMode(_ value: Bool) {
        if privateMode != value { privateMode = value }
    }

    // MARK: Editing the URL

    func startEdit() {
        guard url != nil, !editingURL else { return }
        urlDraft = url ?? ""
        editingURL = true
    }

    func endEdit() {
        guard editingURL else { return }
        editingURL = false
        window?.clearFocus()
    }

    /// Replaces the link on screen with an edited one. If the new domain has a
    /// saved rule it goes straight through, as it would have arriving that way.
    func commitEdit() {
        let next = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queue.isEmpty, Self.isWebURL(next) else {
            urlInvalid = true
            return
        }
        guard next != queue[0] else {
            endEdit()
            return
        }

        forceAsk.remove(queue[0])
        // An edited link still came from the same app.
        let source = sourceByURL.removeValue(forKey: queue[0])
        if let duplicate = queue.firstIndex(of: next), duplicate > 0 {
            queue.remove(at: duplicate)
            sourceByURL[next] = nil
        }
        queue[0] = next
        if let source { sourceByURL[next] = source }
        endEdit()

        drain()
        stateChanged()
        if queue.isEmpty { window?.hide() }
    }

    // MARK: Screens

    func show(_ next: Screen) {
        screen = next
        if next == .settings {
            window?.activate()
            draft = data.handlers
            openHandler = nil
            setTab(tab)
        }
    }

    func openSettings(tab: Tab? = nil) {
        if let tab { self.tab = tab }
        show(.settings)
    }

    func setTab(_ next: Tab) {
        tab = next
        // Re-read on each visit: registering as default happens on another tab.
        if next == .about { refreshAbout() }
        if next == .general { loginItem = currentLoginItem() }
    }

    // MARK: Keyboard

    // Physical keys 1–9 on an ANSI layout, for layouts where the digit row
    // types something else without Shift.
    private static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private static func digit(for event: NSEvent) -> Int? {
        if let raw = event.characters(byApplyingModifiers: []), raw.count == 1,
           let value = Int(raw), (1...9).contains(value) {
            return value
        }
        return digitKeyCodes[event.keyCode]
    }

    /// Returns true when the key was acted on, so the caller can consume it. A
    /// key that reaches AppKit unconsumed, with nothing focused that wants it,
    /// plays the system alert sound.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // Escape
            if editingURL { endEdit() }
            else if screen == .settings { show(.picker) }
            else if !filter.isEmpty { filter = "" }
            else { dismiss() }
            return true
        }

        guard screen == .picker, !editingURL else { return false }

        if flags.contains(.command) && key == "c" {
            copyURL()
            return true
        }
        // ⌘L, as in a browser's address bar.
        if flags.contains(.command) && key == "l" {
            startEdit()
            return true
        }
        if flags.contains(.command) || flags.contains(.control) { return false }

        let remember = flags.contains(.shift) || self.remember
        let privately = flags.contains(.option)
        let shown = visibleHandlers

        if event.keyCode == 36 || event.keyCode == 76 { // Return, Enter
            if let first = shown.first, url != nil { choose(first.id, remember: remember, privately: privately) }
            return true
        }

        // Shift and ⌥ turn digits into symbols; digit(for:) reads the key
        // unmodified, so ⇧2 and ⌥2 still mean the second handler.
        if let digit = Self.digit(for: event) {
            if digit <= shown.count, url != nil {
                choose(shown[digit - 1].id, remember: remember, privately: privately)
            }
            return true
        }

        if event.keyCode == 51 { // Delete
            if !filter.isEmpty { filter = privately ? "" : String(filter.dropLast()) }
            return true
        }

        // Any other printable key narrows the list. ⌥ produces symbols (å, ∫, …)
        // rather than the letter pressed, so it never types into the filter.
        guard let typed = event.characters, typed.count == 1, let scalar = typed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) // arrows and function keys
        else { return false }
        if url != nil && !privately && (!filter.isEmpty || typed != " ") { filter += typed }
        return true
    }

    // MARK: Settings: handlers

    private func saveDraft() {
        let clean = draft.map { handler -> Handler in
            var copy = handler
            copy.args = handler.args.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return copy
        }
        config.replaceHandlers(clean)
        stateChanged()
    }

    func moveDraft(_ index: Int, by delta: Int) {
        let target = index + delta
        guard draft.indices.contains(index), draft.indices.contains(target) else { return }
        draft.swapAt(index, target)
    }

    func removeDraft(_ id: String) {
        if openHandler == id { openHandler = nil }
        draft.removeAll { $0.id == id }
    }

    func addHandler() {
        let handler = Handler(name: "New handler", command: "/usr/bin/open",
                              args: ["-a", "/Applications/Safari.app", "{url}"])
        draft.append(handler)
        openHandler = handler.id
    }

    /// Re-detecting keeps the id of any handler that still launches the same
    /// thing, so saved domains survive. Only the ones whose browser or profile
    /// is gone are lost, and those are worth asking about by name.
    func rediscover() async {
        let handlers = config.nextHandlers()
        let lost = config.domainsLost(with: handlers)
            + config.sourcesLost(with: handlers).map { "links from \(SourceApps.info(for: $0).name)" }

        if !lost.isEmpty {
            let one = lost.count == 1
            let shown = lost.prefix(5).joined(separator: ", ")
            let rest = lost.count - 5
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Re-detect browsers?"
            alert.informativeText =
                "\(lost.count) saved rule\(one ? "" : "s") point\(one ? "s" : "") at a handler that is no " +
                "longer installed, so \(one ? "it" : "they") will be forgotten: " +
                "\(shown)\(rest > 0 ? ", and \(rest) more" : "").\n\n" +
                "Those links will start asking again. Every other saved rule is kept."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Re-detect and forget").hasDestructiveAction = true

            let response: NSApplication.ModalResponse
            if let sheetParent = window?.window, sheetParent.isVisible {
                response = await alert.beginSheetModal(for: sheetParent)
            } else {
                response = alert.runModal()
            }
            guard response == .alertSecondButtonReturn else { return }
        }

        config.rediscover(handlers)
        refreshHandlerIcons()
        stateChanged()
        openHandler = nil
        draft = data.handlers
    }

    // MARK: Settings: domains

    func removeRule(_ domain: String) {
        config.removeRule(domain)
        stateChanged()
    }

    // MARK: Settings: apps

    func setSourceRule(_ bundleID: String, handlerId: String) {
        config.setSourceRule(bundleID: bundleID, handlerId: handlerId)
        stateChanged()
    }

    func removeSourceRule(_ bundleID: String) {
        config.removeSourceRule(bundleID)
        stateChanged()
    }

    /// Lets the user pick an app to add a rule for, without waiting for a link
    /// from it. It starts out pointing at the first handler.
    func addSourceApp() {
        guard let first = data.handlers.first else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose an app. Links from it will open with the handler you pick."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let add: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            // Keep the handler of an app that already has a rule.
            if Rules.matchSource(self.data.sourceRules, bundleID: id) != nil { return }
            self.setSourceRule(id, handlerId: first.id)
        }
        if let parent = window?.window, parent.isVisible {
            panel.beginSheetModal(for: parent, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }

    func favicon(for domain: String) -> NSImage? {
        guard let version = faviconVersions[domain] else { return nil }
        if let cached = images[domain], cached.version == version { return cached.image }
        let image = favicons.file(for: domain).flatMap { NSImage(contentsOf: $0) }
        images[domain] = (version, image)
        return image
    }

    // MARK: Settings: general

    func setDoorbell(_ value: Bool) {
        config.setDoorbell(value)
        stateChanged()
        // Turning it on is the natural moment to hear what it sounds like.
        if value { Doorbell.ring() }
    }

    func setPickerPlacement(_ value: PickerPlacement) {
        config.setPickerPlacement(value)
        stateChanged()
    }

    func setAppearance(_ value: Appearance) {
        config.setAppearance(value)
        stateChanged()
        applyAppearance()
    }

    /// Set on the whole app, so the window, its vibrancy, menus and alerts all
    /// switch together. The palette in Theme is dynamic and follows along.
    func applyAppearance() {
        switch data.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setPageTitles(_ value: Bool) {
        config.setPageTitles(value)
        stateChanged()
        // Picks up the link already on screen, or clears its title.
        loadPageTitle()
    }

    func setCopyOnOpen(_ value: Bool) {
        config.setCopyOnOpen(value)
        stateChanged()
    }

    func setMenuBar(_ value: Bool) {
        config.setMenuBar(value)
        // Without the menu bar Doorman quits as soon as it has nothing to show,
        // so starting it at login would only start it to quit.
        if !value { registerLoginItem(false) }
        stateChanged()
        onMenuBarChange?()
    }

    // Opening at login is registered with macOS (System Settings › General ›
    // Login Items), which stays the source of truth: the user can switch it off
    // there too, so it is read back rather than stored in handlers.json.
    private func currentLoginItem() -> LoginItemState {
        // A bare executable (swift run) is not something to start at login.
        guard packaged else { return LoginItemState() }
        switch SMAppService.mainApp.status {
        case .enabled: return LoginItemState(available: true, enabled: true)
        case .requiresApproval: return LoginItemState(available: true, enabled: true, needsApproval: true)
        default: return LoginItemState(available: true)
        }
    }

    func refreshLoginItem() { loginItem = currentLoginItem() }

    private func registerLoginItem(_ value: Bool) {
        guard packaged else { return }
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Registration can fail if the app isn't in /Applications; the state
            // read that follows shows it still off.
        }
    }

    func setOpenAtLogin(_ value: Bool) {
        registerLoginItem(value && data.menuBar)
        loginItem = currentLoginItem()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([config.file])
    }

    func setDefaultBrowser() async {
        guard packaged else {
            defaultNote = "Only works from the app bundle — run `./build.sh --install` first."
            return
        }
        do {
            let app = Bundle.main.bundleURL
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
            defaultNote = "Requested. Confirm the change if macOS asks; it's also under System Settings › Desktop & Dock › Default web browser."
        } catch {
            defaultNote = "macOS declined the request. Set it manually in System Settings › Desktop & Dock."
        }
        refreshAbout()
    }

    // MARK: Settings: about

    private func isDefaultBrowser() -> Bool {
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return ["http://example.com", "https://example.com"].allSatisfy { probe in
            guard let url = URL(string: probe), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                return false
            }
            return app.resolvingSymlinksInPath().standardizedFileURL == me
        }
    }

    func refreshAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        // Home shortened to ~, so the path fits the row without truncation.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = supportDirectory.path.hasPrefix(home)
            ? "~" + supportDirectory.path.dropFirst(home.count)
            : supportDirectory.path
        about = AboutInfo(version: version, folder: folder, isDefault: isDefaultBrowser(), packaged: packaged)
    }

    // MARK: Window size

    @ObservationIgnored private var requestedHeight: CGFloat?

    /// Resizing the window from inside SwiftUI's layout pass (where geometry
    /// changes are reported) leaves the content laid out for the old size, so
    /// the resize waits for the next turn of the run loop, keeping only the
    /// latest request.
    func requestHeight(_ height: CGFloat) {
        let scheduled = requestedHeight != nil
        requestedHeight = height
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let height = self.requestedHeight else { return }
            self.requestedHeight = nil
            self.window?.fit(contentHeight: height)
        }
    }
}
