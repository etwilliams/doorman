import Foundation

/// Finds the web links in a piece of text, for the Services menu.
public enum LinkExtractor {
    /// Enough for any real selection; a pasted log file shouldn't queue thousands.
    public static let limit = 20

    /// Every http(s) link in `text`, in order, without repeats. Bare domains
    /// such as `github.com/fleetio` count, as macOS's own link detection sees
    /// them; mail addresses and other schemes do not.
    public static func urls(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var seen = Set<String>()
        var found: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else { continue }
            let string = url.absoluteString
            if seen.insert(string).inserted { found.append(string) }
            if found.count == limit { break }
        }
        return found
    }
}
