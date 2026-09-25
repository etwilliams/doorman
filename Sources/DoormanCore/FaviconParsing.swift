import Foundation

/// The parts of favicon fetching that are just parsing: which bytes are an
/// image, and which of a page's declared icons to try first.
public enum FaviconParsing {
    public static let types: [(ext: String, mime: String)] = [
        ("png", "image/png"),
        ("ico", "image/x-icon"),
        ("gif", "image/gif"),
        ("jpg", "image/jpeg"),
        ("webp", "image/webp"),
        ("svg", "image/svg+xml"),
    ]

    public static let extensions = Set(types.map(\.ext))

    private static let domainPattern = try! NSRegularExpression(pattern: "^[a-z0-9-]+(\\.[a-z0-9-]+)*$")

    /// Rule keys are already normalized hostnames, but they end up in file paths
    /// and URLs, so anything that is not plainly a hostname is refused outright.
    public static func isSafeDomain(_ domain: String) -> Bool {
        domain.utf8.count <= 253 && matches(domainPattern, domain)
    }

    /// Decides the format from the bytes rather than the Content-Type header,
    /// which is often wrong for .ico and is an HTML 404 page as often as not.
    public static func sniff(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        let head4 = Array(bytes[0..<4])
        if head4 == [0x89, 0x50, 0x4e, 0x47] { return "png" }
        if head4 == [0x00, 0x00, 0x01, 0x00] { return "ico" }
        if bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff { return "jpg" }
        if head4 == Array("GIF8".utf8) { return "gif" }
        if bytes.count >= 12, head4 == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "webp"
        }
        let text = String(decoding: data.prefix(1024), as: UTF8.self)
        let head = String(text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })).lowercased()
        if (head.hasPrefix("<svg") || head.hasPrefix("<?xml")) && head.contains("<svg") { return "svg" }
        return nil
    }

    private static let linkTag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(
        pattern: "([a-zA-Z:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")
    private static let iconRel = try! NSRegularExpression(pattern: "(^|\\s)(icon|apple-touch-icon)(\\s|$)")
    private static let svgHref = try! NSRegularExpression(pattern: "\\.svg(\\?|$)", options: .caseInsensitive)

    public static func attributes(_ tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let ns = tag as NSString
        for match in attribute.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).lazy
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
                .map { ns.substring(with: $0) } ?? ""
            attrs[name] = value
        }
        return attrs
    }

    struct Link {
        let rel: String
        let href: String
        let sizes: String
        let type: String
    }

    /// Ranks the page's declared icons for display at 16px: something sized for
    /// small use first, then SVG, then whatever is left, with apple-touch-icon
    /// (large, and often a different design) last.
    static func rank(_ link: Link) -> Double {
        let rels = link.rel.split(whereSeparator: \.isWhitespace)
        let sizes = link.sizes.split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0.prefix(while: \.isNumber)) }
            .filter { $0 != 0 }
        guard rels.contains("icon") else { return 1 }
        if sizes.contains(where: { (16...64).contains($0) }) { return 4 }
        if link.type == "image/svg+xml" || matches(svgHref, link.href) { return 3 }
        if sizes.isEmpty { return 2 }
        return 1.5
    }

    /// The icons a page declares, best first, resolved against `base`.
    public static func iconLinks(html: String, base: URL) -> [URL] {
        let ns = html as NSString
        var links: [(Link, URL)] = []
        for match in linkTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = attributes(ns.substring(with: match.range))
            let rel = (attrs["rel"] ?? "").lowercased()
            guard matches(iconRel, rel), let rawHref = attrs["href"], !rawHref.isEmpty,
                  let href = URL(string: rawHref.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
                  let scheme = href.scheme?.lowercased(), scheme == "https" || scheme == "http"
            else { continue }
            let link = Link(rel: rel, href: href.absoluteString,
                            sizes: (attrs["sizes"] ?? "").lowercased(), type: (attrs["type"] ?? "").lowercased())
            links.append((link, href))
        }
        // Stable: equal ranks keep the page's own order.
        return links.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(a.element.0), rank(b.element.0))
                return ra != rb ? ra > rb : a.offset < b.offset
            }
            .map { $0.element.1 }
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }
}
