import Foundation

/// One way of opening a link: a command and its arguments. `{url}` marks where
/// the link goes; if no argument contains it, the link is appended last.
public struct Handler: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var color: String
    public var command: String
    public var args: [String]
    /// Only hand-written in the JSON; kept so a save from Settings keeps it.
    public var privateArgs: [String]?

    public init(
        id: String = newId(),
        name: String,
        subtitle: String = "",
        color: String = "#6b7280",
        command: String,
        args: [String] = ["{url}"],
        privateArgs: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.color = color
        self.command = command
        self.args = args
        self.privateArgs = privateArgs
    }

    /// Builds a handler from whatever was in handlers.json, filling in anything
    /// missing or mistyped rather than refusing the file.
    public static func normalized(from raw: Any) -> Handler {
        let dict = raw as? [String: Any] ?? [:]
        let id = (dict["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? newId()
        let args = (dict["args"] as? [Any]).map { $0.map(jsString) } ?? ["{url}"]
        return Handler(
            id: id,
            name: stringOr(dict["name"], "Untitled"),
            subtitle: stringOr(dict["subtitle"], ""),
            color: stringOr(dict["color"], "#6b7280"),
            command: stringOr(dict["command"], ""),
            args: args,
            privateArgs: (dict["privateArgs"] as? [Any]).map { $0.map(jsString) }
        )
    }

    /// Re-applies the same clean-up to a handler edited in Settings.
    public func normalized() -> Handler {
        var copy = self
        if copy.id.isEmpty { copy.id = Handler.newId() }
        if copy.name.isEmpty { copy.name = "Untitled" }
        if copy.color.isEmpty { copy.color = "#6b7280" }
        return copy
    }

    /// The extra arguments that open a link in a private window, or nil when the
    /// handler has no such mode. Safari, launched through `open -a`, has none.
    /// A handler can declare its own with "privateArgs" in handlers.json.
    public var privateModeArgs: [String]? {
        if let privateArgs { return privateArgs.isEmpty ? nil : privateArgs }
        if Discovery.chromiumBinaries.contains(command) { return ["--incognito"] }
        if (command as NSString).lastPathComponent.lowercased() == "firefox" { return ["-private-window"] }
        return nil
    }

    /// The argv (after the command) that opens `url`, or nil when a private
    /// window was asked for and this handler cannot do one. The URL is always
    /// its own entry, so nothing in it can be read as another argument.
    /// Private-window flags go just before the URL, where Firefox's
    /// -private-window wants it.
    public func launchArguments(for url: String, privately: Bool = false) -> [String]? {
        var extra: [String] = []
        if privately {
            guard let flags = privateModeArgs else { return nil }
            extra = flags
        }
        var out = args.map { $0.replacingOccurrences(of: "{url}", with: url) }
        if let index = args.firstIndex(where: { $0.contains("{url}") }) {
            out.insert(contentsOf: extra, at: index)
        } else {
            out += extra + [url]
        }
        return out
    }

    public static func newId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

// JavaScript's String(value), near enough for values read from JSON.
func jsString(_ value: Any) -> String {
    switch value {
    case let string as String: return string
    case let number as NSNumber: return isBool(number) ? (number.boolValue ? "true" : "false") : number.stringValue
    case is NSNull: return "null"
    default: return String(describing: value)
    }
}

// `String(value || fallback)`: anything falsy takes the fallback.
func stringOr(_ value: Any?, _ fallback: String) -> String {
    guard let value, isTruthy(value) else { return fallback }
    return jsString(value)
}

func isTruthy(_ value: Any?) -> Bool {
    switch value {
    case nil, is NSNull: return false
    case let string as String: return !string.isEmpty
    case let number as NSNumber: return number.boolValue
    default: return true
    }
}

func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}
