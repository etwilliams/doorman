import AppKit
import DoormanCore

/// Backs "Open Links with Doorman" in the Services menu (NSServices in
/// Info.plist): the links in whatever text is selected, in any app, go through
/// Doorman as if they had been clicked.
@MainActor
final class ServiceProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    // Selector openLinks:userData:error:, named by NSMessage in Info.plist.
    @objc func openLinks(_ pasteboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var text = pasteboard.string(forType: .string) ?? ""
        // A selected link or file-less URL can arrive as a URL rather than text.
        for url in pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [] where !url.isFileURL {
            text += "\n" + url.absoluteString
        }

        let links = LinkExtractor.urls(in: text)
        guard !links.isEmpty else {
            error.pointee = "The selection doesn't contain a web link." as NSString
            return
        }

        // The app the service was chosen in is still in front, so it is the
        // links' source, for app rules.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let source = front == Bundle.main.bundleIdentifier ? nil : front
        for link in links { model.enqueue(link, source: source) }
    }
}
