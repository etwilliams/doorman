import AppKit
import Darwin
import DoormanCore

/// An app that links come from, as Settings and the picker show it.
struct SourceAppInfo {
    let name: String
    let icon: NSImage?
}

/// Works out which app sent a link, and what to call it.
@MainActor
enum SourceApps {
    private static var infoCache: [String: SourceAppInfo] = [:]

    /// The bundle id of the app behind a process: the outermost .app its
    /// executable lives in, so helpers count as their app. A process outside
    /// any app, such as `open` run in Terminal, is traced up through its parents
    /// to the app that started it.
    static func bundleID(forPID pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<8 {
            guard current > 1 else { return nil }
            if let path = executablePath(of: current),
               let bundle = Discovery.appBundlePath(containing: path),
               let id = Bundle(path: bundle)?.bundleIdentifier {
                // Doorman reopening its own links is not a source worth a rule.
                return id == Bundle.main.bundleIdentifier ? nil : id
            }
            guard let parent = parentPID(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The app's name and icon, or its bundle id and no icon once it has been
    /// uninstalled.
    static func info(for bundleID: String) -> SourceAppInfo {
        if let cached = infoCache[bundleID] { return cached }
        let info: SourceAppInfo
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            info = SourceAppInfo(name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            info = SourceAppInfo(name: bundleID, icon: nil)
        }
        infoCache[bundleID] = info
        return info
    }
}
