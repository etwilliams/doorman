import AppKit

// AppKit owns the lifecycle rather than SwiftUI's App: Doorman's one window is
// shown, hidden and sized by hand, and links arrive as Apple events.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
