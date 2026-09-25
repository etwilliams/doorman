import AppKit
import DoormanCore

/// Saved domains get their site's icon cached on disk next to handlers.json,
/// one file per domain, named <domain>.<ext>. Icons are fetched from the site
/// itself, never a third-party favicon service, so no list of saved domains
/// leaves the machine.
@MainActor
final class Favicons {
    nonisolated static let maxPageBytes = 512 * 1024
    nonisolated static let maxIconBytes = 256 * 1024
    nonisolated static let maxCandidates = 4

    let dir: URL
    private let isWanted: (String) -> Bool
    private let onChange: () -> Void
    private var inFlight = Set<String>()
    // A site with no usable icon is not retried until the next launch, so a
    // state change never turns into a fetch loop.
    private var failed = Set<String>()
    private let session: URLSession
    // Icons for links shown in the picker, by origin. Kept in memory only, for
    // the same reason Recent is: which sites were opened stays off disk.
    private var linkIcons: [String: NSImage] = [:]
    private var linkIconsMissing = Set<String>()
    private var linkIconsInFlight: [String: Task<NSImage?, Never>] = [:]

    init(dir: URL, isWanted: @escaping (String) -> Bool, onChange: @escaping () -> Void) {
        self.dir = dir
        self.isWanted = isWanted
        self.onChange = onChange

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    private func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private static func split(_ name: String) -> (domain: String, ext: String)? {
        let ext = (name as NSString).pathExtension
        guard FaviconParsing.extensions.contains(ext) else { return nil }
        return ((name as NSString).deletingPathExtension, ext)
    }

    func file(for domain: String) -> URL? {
        guard FaviconParsing.isSafeDomain(domain) else { return nil }
        for (ext, _) in FaviconParsing.types {
            let url = dir.appendingPathComponent("\(domain).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Maps each cached domain to a version stamp (its mtime), so a refreshed
    /// icon is not served from the in-memory image cache.
    func list() -> [String: Int] {
        var versions: [String: Int] = [:]
        for name in files() {
            guard let (domain, _) = Self.split(name), FaviconParsing.isSafeDomain(domain),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path),
                  let modified = attrs[.modificationDate] as? Date
            else { continue }
            versions[domain] = Int(modified.timeIntervalSince1970 * 1000)
        }
        return versions
    }

    /// Brings the directory in line with the saved domains: forgets icons for
    /// domains no longer saved, and fetches the ones that are missing.
    func sync(_ domains: [String]) {
        let wanted = Set(domains.filter(FaviconParsing.isSafeDomain))
        let have = list()
        // Forgetting a domain clears its failure too, so saving it again retries.
        failed.formIntersection(wanted)

        for name in files() {
            guard let (domain, _) = Self.split(name), !wanted.contains(domain) else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }

        for domain in wanted where have[domain] == nil && !inFlight.contains(domain) && !failed.contains(domain) {
            fetch(domain)
        }
    }

    private func fetch(_ domain: String) {
        inFlight.insert(domain)
        let session = self.session
        Task {
            let icon = await Self.fetchIcon(domain, session: session)
            inFlight.remove(domain)
            guard let icon else {
                failed.insert(domain)
                return
            }
            // The rule may have been forgotten while the fetch was out.
            guard isWanted(domain) else { return }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try icon.data.write(to: dir.appendingPathComponent("\(domain).\(icon.ext)"), options: .atomic)
                onChange()
            } catch {
                failed.insert(domain)
            }
        }
    }

    /// The icon for the site a link points at, for the picker. A saved
    /// domain's icon comes from the cache folder; anything else is fetched once
    /// per launch from the link's own origin and held in memory.
    func icon(forLink link: String) async -> NSImage? {
        guard let parts = URLComponents(string: link), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), FaviconParsing.isSafeDomain(host)
        else { return nil }

        if let domain = Rules.domain(forHost: host), let file = file(for: domain),
           let image = NSImage(contentsOf: file) {
            return image
        }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parts.port
        origin.path = "/"
        guard let home = origin.url else { return nil }
        let key = home.absoluteString

        if let image = linkIcons[key] { return image }
        if linkIconsMissing.contains(key) { return nil }
        // Several queued links on one site share a single fetch.
        if let pending = linkIconsInFlight[key] { return await pending.value }

        let session = self.session
        let task = Task { () -> NSImage? in
            guard let icon = await Self.fetchIcon(home: home, session: session) else { return nil }
            return NSImage(data: icon.data)
        }
        linkIconsInFlight[key] = task
        let image = await task.value
        linkIconsInFlight[key] = nil
        if let image { linkIcons[key] = image } else { linkIconsMissing.insert(key) }
        return image
    }

    nonisolated static func fetchIcon(_ domain: String, session: URLSession) async -> (ext: String, data: Data)? {
        guard let home = URL(string: "https://\(domain)/") else { return nil }
        return await fetchIcon(home: home, session: session)
    }

    /// Resolves a site to icon bytes: the icons its home page declares, then
    /// the conventional /favicon.ico at wherever the home page redirected to.
    nonisolated static func fetchIcon(home: URL, session: URLSession) async -> (ext: String, data: Data)? {
        let page = await get(home, maxBytes: maxPageBytes, session: session)
        let base = page?.url ?? home
        let html = page.map { String(decoding: $0.data, as: UTF8.self) } ?? ""

        var candidates = FaviconParsing.iconLinks(html: html, base: base)
        if let fallback = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL { candidates.append(fallback) }

        var tried = Set<URL>()
        for url in candidates where !tried.contains(url) {
            if tried.count >= maxCandidates { break }
            tried.insert(url)
            if let icon = await get(url, maxBytes: maxIconBytes, session: session),
               let ext = FaviconParsing.sniff(icon.data) {
                return (ext, icon.data)
            }
        }
        return nil
    }

    nonisolated static func get(_ url: URL, maxBytes: Int, session: URLSession) async -> (url: URL, data: Data)? {
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(maxBytes)
            else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return (http.url ?? url, data)
        } catch {
            return nil
        }
    }
}
