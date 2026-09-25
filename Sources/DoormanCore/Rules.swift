import Foundation

public enum Rules {
    /// Rules are keyed by registrable-ish domain: the hostname with a leading
    /// "www." removed. A rule matches that domain and everything under it, so
    /// saving github.com also covers gist.github.com.
    public static func domain(forHost host: String?) -> String? {
        guard let host else { return nil }
        var clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.hasPrefix("www.") { clean.removeFirst(4) }
        return clean.isEmpty ? nil : clean
    }

    /// The saved domain that covers `host`. Longest match wins, so a rule for
    /// docs.example.com beats one for example.com.
    public static func match(_ rules: [String: String], host: String?) -> String? {
        let clean = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !clean.isEmpty else { return nil }

        var best: String?
        for domain in rules.keys {
            guard clean == domain || clean.hasSuffix(".\(domain)") else { continue }
            if best == nil || domain.count > best!.count { best = domain }
        }
        return best
    }

    /// Drops rules whose handler is gone, and re-normalizes their domains.
    public static func prune(_ rules: [String: Any], handlers: [Handler]) -> [String: String] {
        let ids = Set(handlers.map(\.id))
        var kept: [String: String] = [:]
        for (domain, value) in rules {
            guard let handlerId = value as? String, ids.contains(handlerId),
                  let clean = Rules.domain(forHost: domain) else { continue }
            kept[clean] = handlerId
        }
        return kept
    }

    /// Drops app rules whose handler is gone, or whose bundle id is blank.
    public static func pruneSources(_ rules: [String: Any], handlers: [Handler]) -> [String: String] {
        let ids = Set(handlers.map(\.id))
        var kept: [String: String] = [:]
        for (bundleID, value) in rules {
            let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let handlerId = value as? String, ids.contains(handlerId), !clean.isEmpty else { continue }
            kept[clean] = handlerId
        }
        return kept
    }

    /// The app rule key for a bundle id, compared case-insensitively as
    /// LaunchServices does.
    public static func matchSource(_ rules: [String: String], bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return rules.keys.first { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// A handler is "the same" across a re-detect when it launches the same
    /// thing: the browser binary and its arguments, including the profile
    /// directory. Names, colors and subtitles are cosmetic and get refreshed.
    static func signature(of handler: Handler) -> [String] {
        [handler.command] + handler.args
    }

    /// Carries ids over from the current handlers to freshly discovered ones,
    /// so saved domains keep pointing at the browser profile the user chose.
    public static func preserveIds(discovered: [Handler], existing: [Handler]) -> [Handler] {
        var idBySignature: [[String]: String] = [:]
        for handler in existing where idBySignature[signature(of: handler)] == nil {
            idBySignature[signature(of: handler)] = handler.id
        }

        var taken = Set<String>()
        return discovered.map { handler in
            guard let id = idBySignature[signature(of: handler)], !taken.contains(id) else { return handler }
            taken.insert(id)
            var copy = handler
            copy.id = id
            return copy
        }
    }
}
