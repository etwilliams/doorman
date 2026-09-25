import AppKit
import DoormanCore

/// What a handler looks like: the app it launches, and for a Chromium
/// profile, the account photo that profile is signed in with.
struct HandlerArtwork {
    var app: NSImage?
    var photo: NSImage?
}

/// Looks up and caches handler artwork. Keyed by what the handler launches,
/// so editing its command in Settings picks up the new app straight away.
@MainActor
final class HandlerIcons {
    private var cache: [[String]: HandlerArtwork] = [:]

    func artwork(for handler: Handler) -> HandlerArtwork {
        let key = [handler.command] + handler.args
        if let cached = cache[key] { return cached }
        let artwork = HandlerArtwork(
            app: Self.appURL(for: handler).map { NSWorkspace.shared.icon(forFile: $0.path) },
            photo: Discovery.profilePicture(for: handler).flatMap { NSImage(contentsOf: $0) }
        )
        cache[key] = artwork
        return artwork
    }

    /// Forgets everything, so a photo changed in the browser shows next time.
    func reset() { cache.removeAll() }

    private static func appURL(for handler: Handler) -> URL? {
        switch Discovery.appReference(for: handler) {
        case .path(let path):
            let expanded = (path as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        case .name(let name):
            // Where `open -a` itself would look for an app named on its own.
            let file = name.hasSuffix(".app") ? name : "\(name).app"
            return ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        case .bundleID(let id):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        case nil:
            return nil
        }
    }
}
