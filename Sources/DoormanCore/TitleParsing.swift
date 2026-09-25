import Foundation

/// Pulls a page's title out of its HTML, for the picker.
public enum TitleParsing {
    public static let maxLength = 160

    private static let titleTag = try! NSRegularExpression(
        pattern: "<title\\b[^>]*>(.*?)</title\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive)

    /// The page's `<title>`, or its `og:title` when that is missing or blank,
    /// decoded and tidied to one line.
    public static func title(fromHTML html: String) -> String? {
        let ns = html as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let match = titleTag.firstMatch(in: html, range: whole),
           let title = clean(ns.substring(with: match.range(at: 1))) {
            return title
        }
        for match in metaTag.matches(in: html, range: whole) {
            let attrs = FaviconParsing.attributes(ns.substring(with: match.range))
            let key = (attrs["property"] ?? attrs["name"] ?? "").lowercased()
            if key == "og:title" || key == "twitter:title", let title = clean(attrs["content"] ?? "") {
                return title
            }
        }
        return nil
    }

    static func clean(_ raw: String) -> String? {
        let text = decodeEntities(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "copy": "©", "reg": "®", "trade": "™",
    ]
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});")

    /// The HTML entities titles actually use; anything unknown is left as written.
    static func decodeEntities(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                decoded = named[body.lowercased()]
            }
            out += decoded ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
