import Foundation
import DoormanCore

/// Fetches page titles for the picker, when Settings allows it. Each link's
/// page is requested once per launch, without cookies, and only read if it is
/// HTML. Titles are held in memory only.
@MainActor
final class PageTitles {
    nonisolated static let maxBytes = 384 * 1024

    private var titles: [String: String] = [:]
    private var missing = Set<String>()
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        session = URLSession(configuration: configuration)
    }

    func title(for link: String) async -> String? {
        if let title = titles[link] { return title }
        if missing.contains(link) { return nil }
        // Queued duplicates and quick re-shows share one request.
        if let pending = inFlight[link] { return await pending.value }
        guard let url = URL(string: link) else { return nil }

        let session = self.session
        let task = Task { await Self.fetch(url, session: session) }
        inFlight[link] = task
        let title = await task.value
        inFlight[link] = nil
        if let title { titles[link] = title } else { missing.insert(link) }
        return title
    }

    nonisolated static func fetch(_ url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            // Anything but a page (a PDF, a download) is left unread.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased().contains("html") == true
            else { return nil }

            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                // The title is in the head; stop as soon as that is over.
                if data.count % 4096 == 0, headEnded(data) { break }
                if data.count >= maxBytes { break }
            }
            return TitleParsing.title(fromHTML: decode(data, encodingName: http.textEncodingName))
        } catch {
            return nil
        }
    }

    private nonisolated static func headEnded(_ data: Data) -> Bool {
        data.range(of: Data("</head".utf8)) != nil || data.range(of: Data("</HEAD".utf8)) != nil
    }

    private nonisolated static func decode(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
