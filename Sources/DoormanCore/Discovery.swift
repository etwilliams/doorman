import Foundation

/// Builds a starter handler list from what is actually installed on this Mac.
public enum Discovery {
    struct ChromiumBrowser {
        let label: String
        let bin: String
        let stateDir: String
        let color: String
    }

    struct SimpleBrowser {
        let label: String
        let app: String
        let color: String
    }

    static let chromium: [ChromiumBrowser] = [
        .init(label: "Chrome", bin: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              stateDir: "Google/Chrome", color: "#4285f4"),
        .init(label: "Edge", bin: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
              stateDir: "Microsoft Edge", color: "#0f7ac7"),
        .init(label: "Brave", bin: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
              stateDir: "BraveSoftware/Brave-Browser", color: "#fb542b"),
        .init(label: "Chrome Canary",
              bin: "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
              stateDir: "Google/Chrome Canary", color: "#f5c518"),
    ]

    static let simple: [SimpleBrowser] = [
        .init(label: "Safari", app: "/Applications/Safari.app", color: "#2e7cf6"),
        .init(label: "Arc", app: "/Applications/Arc.app", color: "#ff6a6a"),
    ]

    static let firefoxApp = "/Applications/Firefox.app"
    static let firefoxBin = firefoxApp + "/Contents/MacOS/firefox"
    static let firefoxColor = "#ff7139"

    public static let chromiumBinaries = Set(chromium.map(\.bin))

    struct Profile {
        let dir: String
        let name: String
        let email: String
        let color: String?
    }

    public static func discoverHandlers(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Handler] {
        var handlers: [Handler] = []

        for browser in chromium where exists(browser.bin) {
            let profiles = readChromiumProfiles(stateDir: browser.stateDir, home: home, exists: exists)
            if profiles.isEmpty {
                handlers.append(Handler(name: browser.label, color: browser.color, command: browser.bin))
                continue
            }
            for profile in profiles {
                handlers.append(Handler(
                    name: "\(browser.label) — \(profile.name)",
                    subtitle: profile.email,
                    color: profile.color ?? browser.color,
                    command: browser.bin,
                    args: ["--profile-directory=\(profile.dir)", "{url}"]
                ))
            }
        }

        if exists(firefoxApp) {
            // Firefox's own binary rather than `open -a`: `-P` reaches the right
            // profile whether or not Firefox is running, and it hands the link to
            // that profile's open window. With one profile there is nothing to
            // choose, so it stays a plain "Firefox".
            let profiles = readFirefoxProfiles(home: home, exists: exists)
            if profiles.count < 2 {
                handlers.append(Handler(name: "Firefox", color: firefoxColor, command: firefoxBin))
            } else {
                for name in profiles {
                    handlers.append(Handler(
                        name: "Firefox — \(name)",
                        color: firefoxColor,
                        command: firefoxBin,
                        args: ["-P", name, "{url}"]
                    ))
                }
            }
        }

        for browser in simple where exists(browser.app) {
            handlers.append(Handler(
                name: browser.label,
                color: browser.color,
                command: "/usr/bin/open",
                args: ["-a", browser.app, "{url}"]
            ))
        }
        return handlers
    }

    /// Reads a Chromium "Local State" file and returns its profiles in the order
    /// Chrome itself lists them (Default first, then Profile N by number).
    static func readChromiumProfiles(stateDir: String, home: URL, exists: (String) -> Bool) -> [Profile] {
        let root = home.appendingPathComponent("Library/Application Support").appendingPathComponent(stateDir)
        let statePath = root.appendingPathComponent("Local State").path
        guard exists(statePath),
              let raw = FileManager.default.contents(atPath: statePath),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }

        return cache.keys
            .filter { exists(root.appendingPathComponent($0).path) }
            .sorted { a, b in
                if a == "Default" { return b != "Default" }
                if b == "Default" { return false }
                return a.compare(b, options: [.numeric]) == .orderedAscending
            }
            .map { dir in
                let info = cache[dir] as? [String: Any] ?? [:]
                let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (info["gaia_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? dir
                return Profile(
                    dir: dir,
                    name: name,
                    email: info["user_name"] as? String ?? "",
                    color: swatch(fromChromeColor: info["profile_highlight_color"])
                )
            }
    }

    /// The profile names in Firefox's profiles.ini, in file order. Its
    /// `[ProfileN]` sections each have a `Name=`; `[General]` and the
    /// `[InstallXXXX]` sections don't, and are skipped.
    static func readFirefoxProfiles(home: URL, exists: (String) -> Bool) -> [String] {
        let path = home.appendingPathComponent("Library/Application Support/Firefox/profiles.ini").path
        guard exists(path),
              let raw = FileManager.default.contents(atPath: path),
              let text = String(data: raw, encoding: .utf8)
        else { return [] }

        var names: [String] = []
        var inProfile = false
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inProfile = line.range(of: #"^\[Profile\d+\]$"#, options: .regularExpression) != nil
            } else if inProfile, line.hasPrefix("Name=") {
                let name = String(line.dropFirst("Name=".count))
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// How a handler names the app it launches, for showing that app's icon.
    public enum AppReference: Equatable, Sendable {
        case path(String)
        case name(String)
        case bundleID(String)
    }

    /// The app a handler opens: the bundle around its binary, or the target of
    /// `open -a` / `open -b`. Nil for anything else, such as curl.
    public static func appReference(for handler: Handler) -> AppReference? {
        let command = handler.command
        if let bundle = appBundlePath(containing: command) { return .path(bundle) }
        guard (command as NSString).lastPathComponent == "open" else { return nil }

        let args = handler.args
        for (index, arg) in args.enumerated() where index + 1 < args.count {
            let value = args[index + 1]
            switch arg {
            case "-a":
                return value.contains("/") || value.hasSuffix(".app") ? .path(value) : .name(value)
            case "-b":
                return .bundleID(value)
            default:
                continue
            }
        }
        return nil
    }

    /// The outermost .app bundle a path is inside, or is. Outermost, so a
    /// helper tucked in Slack.app/Contents/Frameworks/… counts as Slack.
    public static func appBundlePath(containing path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    /// The signed-in account photo Chromium keeps for a handler's profile, if
    /// it is one Discovery would build: a known Chromium binary launched with
    /// --profile-directory. Chrome names the file in Local State.
    public static func profilePicture(
        for handler: Handler,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        guard let browser = chromium.first(where: { $0.bin == handler.command }),
              let flag = handler.args.first(where: { $0.hasPrefix("--profile-directory=") })
        else { return nil }
        let dir = String(flag.dropFirst("--profile-directory=".count))
        // The directory comes from free text in handlers.json and ends up in a path.
        guard isPlainFileName(dir) else { return nil }

        let root = home.appendingPathComponent("Library/Application Support").appendingPathComponent(browser.stateDir)
        var fileName = "Google Profile Picture.png"
        if let raw = FileManager.default.contents(atPath: root.appendingPathComponent("Local State").path),
           let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any],
           let named = (cache[dir] as? [String: Any])?["gaia_picture_file_name"] as? String,
           isPlainFileName(named) {
            fileName = named
        }

        let picture = root.appendingPathComponent(dir).appendingPathComponent(fileName)
        return exists(picture.path) ? picture : nil
    }

    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// Chrome stores a per-profile theme color as a signed ARGB integer, usually
    /// far too dark to read as a dot on either background. Reuse its hue, but pin
    /// the saturation and lightness to something legible in light and dark mode.
    public static func swatch(fromChromeColor value: Any?) -> String? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded() else { return nil }

        let argb = UInt32(truncatingIfNeeded: number.int64Value)
        let r = Double((argb >> 16) & 0xff) / 255
        let g = Double((argb >> 8) & 0xff) / 255
        let b = Double(argb & 0xff) / 255

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        guard delta != 0 else { return nil }

        var hue: Double
        if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)

        return hslToHex(hue, 0.62, 0.58)
    }

    static func hslToHex(_ h: Double, _ s: Double, _ l: Double) -> String {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) =
            h < 60 ? (c, x, 0) :
            h < 120 ? (x, c, 0) :
            h < 180 ? (0, c, x) :
            h < 240 ? (0, x, c) :
            h < 300 ? (x, 0, c) : (c, 0, x)
        return "#" + [r, g, b]
            .map { String(format: "%02x", Int(((($0 + m) * 255)).rounded())) }
            .joined()
    }
}
