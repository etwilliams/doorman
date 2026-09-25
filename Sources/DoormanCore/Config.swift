import Foundation

/// Light, dark, or whatever macOS is set to.
public enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// Where the picker opens.
public enum PickerPlacement: String, Codable, CaseIterable, Sendable {
    /// Centered over the window of the app the link was clicked in.
    case window
    /// Centered on the screen, a third of the way down.
    case screen
    /// Next to the pointer.
    case pointer
}

/// Everything in handlers.json. The format is shared with the Electron build,
/// so either can read what the other wrote.
public struct ConfigData: Codable, Equatable, Sendable {
    public var handlers: [Handler]
    public var rules: [String: String]
    /// The app a link came from, by bundle id, to the handler it should open
    /// with. Consulted only when no saved domain covers the link.
    public var sourceRules: [String: String]
    public var copyOnOpen: Bool
    /// Off unless chosen: fetching a link before it is opened can use up a
    /// one-time link (a sign-in or reset link) meant for the browser.
    public var pageTitles: Bool
    public var doorbell: Bool
    public var menuBar: Bool
    public var appearance: Appearance
    public var pickerPlacement: PickerPlacement

    public init(handlers: [Handler], rules: [String: String] = [:], sourceRules: [String: String] = [:],
                copyOnOpen: Bool = false, pageTitles: Bool = false,
                doorbell: Bool = false, menuBar: Bool = true, appearance: Appearance = .system,
                pickerPlacement: PickerPlacement = .window) {
        self.handlers = handlers
        self.rules = rules
        self.sourceRules = sourceRules
        self.copyOnOpen = copyOnOpen
        self.pageTitles = pageTitles
        self.doorbell = doorbell
        self.menuBar = menuBar
        self.appearance = appearance
        self.pickerPlacement = pickerPlacement
    }
}

public final class Config {
    public let file: URL
    public private(set) var data: ConfigData
    private let discover: () -> [Handler]

    public init(file: URL, discover: @escaping () -> [Handler] = { Discovery.discoverHandlers() }) {
        self.file = file
        self.discover = discover
        if let loaded = Config.load(file) {
            data = loaded
        } else {
            // Missing or unreadable: start fresh rather than losing the app to a bad file.
            data = ConfigData(handlers: discover())
            write()
        }
    }

    static func load(_ file: URL) -> ConfigData? {
        guard let raw = try? Data(contentsOf: file),
              let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let handlers = (parsed["handlers"] as? [Any] ?? []).map(Handler.normalized(from:))
        // Absent means on: configs written before this setting existed should
        // keep the app in the menu bar, not silently lose it.
        let menuBarOff = (parsed["menuBar"] as? NSNumber).map { isBool($0) && !$0.boolValue } ?? false
        return ConfigData(
            handlers: handlers,
            rules: Rules.prune(parsed["rules"] as? [String: Any] ?? [:], handlers: handlers),
            sourceRules: Rules.pruneSources(parsed["sourceRules"] as? [String: Any] ?? [:], handlers: handlers),
            copyOnOpen: isTruthy(parsed["copyOnOpen"]),
            pageTitles: isTruthy(parsed["pageTitles"]),
            doorbell: isTruthy(parsed["doorbell"]),
            menuBar: !menuBarOff,
            // Absent or unrecognized follows the system.
            appearance: (parsed["appearance"] as? String).flatMap(Appearance.init(rawValue:)) ?? .system,
            pickerPlacement: (parsed["pickerPlacement"] as? String).flatMap(PickerPlacement.init(rawValue:)) ?? .window
        )
    }

    public func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(data).write(to: file, options: .atomic)
        } catch {
            NSLog("Doorman: could not write \(file.path): \(error)")
        }
    }

    public func replaceHandlers(_ handlers: [Handler]) {
        data.handlers = handlers.map { $0.normalized() }
        pruneRules()
        write()
    }

    private func pruneRules() {
        data.rules = Rules.prune(data.rules, handlers: data.handlers)
        data.sourceRules = Rules.pruneSources(data.sourceRules, handlers: data.handlers)
    }

    public func setRule(host: String?, handlerId: String) {
        guard let domain = Rules.domain(forHost: host),
              data.handlers.contains(where: { $0.id == handlerId }) else { return }
        data.rules[domain] = handlerId
        write()
    }

    public func removeRule(_ domain: String) {
        data.rules.removeValue(forKey: domain)
        write()
    }

    public func setSourceRule(bundleID: String, handlerId: String) {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, data.handlers.contains(where: { $0.id == handlerId }) else { return }
        // Bundle ids compare case-insensitively; keep one entry per app.
        for key in data.sourceRules.keys where key.caseInsensitiveCompare(clean) == .orderedSame {
            data.sourceRules.removeValue(forKey: key)
        }
        data.sourceRules[clean] = handlerId
        write()
    }

    public func removeSourceRule(_ bundleID: String) {
        data.sourceRules.removeValue(forKey: bundleID)
        write()
    }

    /// The handler id saved for a link: its domain's rule if there is one,
    /// since that is the more specific choice, otherwise the rule for the app
    /// it came from.
    public func handlerId(forHost host: String?, source: String? = nil) -> String? {
        let ids = Set(data.handlers.map(\.id))
        if let domain = Rules.match(data.rules, host: host), let id = data.rules[domain], ids.contains(id) {
            return id
        }
        if let key = Rules.matchSource(data.sourceRules, bundleID: source), let id = data.sourceRules[key],
           ids.contains(id) {
            return id
        }
        return nil
    }

    public func setCopyOnOpen(_ value: Bool) { data.copyOnOpen = value; write() }
    public func setPageTitles(_ value: Bool) { data.pageTitles = value; write() }
    public func setDoorbell(_ value: Bool) { data.doorbell = value; write() }
    public func setMenuBar(_ value: Bool) { data.menuBar = value; write() }
    public func setAppearance(_ value: Appearance) { data.appearance = value; write() }
    public func setPickerPlacement(_ value: PickerPlacement) { data.pickerPlacement = value; write() }

    /// The handler list a re-detect would produce, ids and all.
    public func nextHandlers() -> [Handler] {
        Rules.preserveIds(discovered: discover(), existing: data.handlers)
    }

    /// Domains whose handler would not survive the given handler list.
    public func domainsLost(with handlers: [Handler]) -> [String] {
        let ids = Set(handlers.map(\.id))
        return data.rules.filter { !ids.contains($0.value) }.map(\.key).sorted()
    }

    /// App bundle ids whose handler would not survive the given handler list.
    public func sourcesLost(with handlers: [Handler]) -> [String] {
        let ids = Set(handlers.map(\.id))
        return data.sourceRules.filter { !ids.contains($0.value) }.map(\.key).sorted()
    }

    public func rediscover(_ handlers: [Handler]? = nil) {
        data.handlers = (handlers ?? nextHandlers()).map { $0.normalized() }
        pruneRules()
        write()
    }
}
