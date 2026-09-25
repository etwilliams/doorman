import XCTest
@testable import DoormanCore

final class RulesTests: XCTestCase {
    func testDomainStripsWwwAndCase() {
        XCTAssertEqual(Rules.domain(forHost: " WWW.GitHub.com "), "github.com")
        XCTAssertEqual(Rules.domain(forHost: "gist.github.com"), "gist.github.com")
        XCTAssertNil(Rules.domain(forHost: "www."))
        XCTAssertNil(Rules.domain(forHost: nil))
    }

    func testMatchCoversSubdomainsAndPrefersLongest() {
        let rules = ["example.com": "a", "docs.example.com": "b", "ample.com": "c"]
        XCTAssertEqual(Rules.match(rules, host: "example.com"), "example.com")
        XCTAssertEqual(Rules.match(rules, host: "www.example.com"), "example.com")
        XCTAssertEqual(Rules.match(rules, host: "api.docs.example.com"), "docs.example.com")
        // A suffix that is not a label boundary is not a match.
        XCTAssertNil(Rules.match(["ample.com": "c"], host: "example.com"))
        XCTAssertNil(Rules.match(rules, host: ""))
    }

    func testPruneDropsMissingHandlersAndRenormalizes() {
        let handlers = [Handler(id: "a", name: "A", command: "/bin/echo")]
        let kept = Rules.prune(["WWW.Example.com": "a", "gone.com": "z", "bad.com": 3], handlers: handlers)
        XCTAssertEqual(kept, ["example.com": "a"])
    }

    func testPreserveIdsMatchesOnCommandAndArgs() {
        let existing = [
            Handler(id: "keep", name: "Old name", command: "/chrome", args: ["--profile-directory=Default", "{url}"]),
            Handler(id: "gone", name: "Gone", command: "/chrome", args: ["--profile-directory=Profile 9", "{url}"]),
        ]
        let discovered = [
            Handler(id: "new1", name: "New name", command: "/chrome", args: ["--profile-directory=Default", "{url}"]),
            Handler(id: "new2", name: "Other", command: "/chrome", args: ["--profile-directory=Profile 1", "{url}"]),
        ]
        let result = Rules.preserveIds(discovered: discovered, existing: existing)
        XCTAssertEqual(result.map(\.id), ["keep", "new2"])
        XCTAssertEqual(result[0].name, "New name")
    }
}

final class HandlerTests: XCTestCase {
    func testUrlSubstitutedInPlace() {
        let handler = Handler(name: "Safari", command: "/usr/bin/open", args: ["-a", "/Applications/Safari.app", "{url}"])
        XCTAssertEqual(handler.launchArguments(for: "https://x.com/?a=1"),
                       ["-a", "/Applications/Safari.app", "https://x.com/?a=1"])
    }

    func testUrlAppendedWhenNoPlaceholder() {
        let handler = Handler(name: "curl", command: "/usr/bin/curl", args: ["-sSL", "-O"])
        XCTAssertEqual(handler.launchArguments(for: "https://x.com"), ["-sSL", "-O", "https://x.com"])
    }

    func testPrivateArgsGoBeforeUrl() {
        let chrome = Handler(name: "Chrome", command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                             args: ["--profile-directory=Default", "{url}"])
        XCTAssertEqual(chrome.launchArguments(for: "https://x.com", privately: true),
                       ["--profile-directory=Default", "--incognito", "https://x.com"])

        let firefox = Handler(name: "Firefox", command: "/Applications/Firefox.app/Contents/MacOS/firefox", args: [])
        XCTAssertEqual(firefox.launchArguments(for: "https://x.com", privately: true),
                       ["-private-window", "https://x.com"])
    }

    func testNoPrivateModeRefuses() {
        let safari = Handler(name: "Safari", command: "/usr/bin/open", args: ["-a", "/Applications/Safari.app", "{url}"])
        XCTAssertNil(safari.privateModeArgs)
        XCTAssertNil(safari.launchArguments(for: "https://x.com", privately: true))

        let declared = Handler(name: "Mine", command: "/usr/bin/open", privateArgs: ["--secret"])
        XCTAssertEqual(declared.privateModeArgs, ["--secret"])
        let optedOut = Handler(name: "Chrome", command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                               privateArgs: [])
        XCTAssertNil(optedOut.privateModeArgs)
    }

    func testNormalizeFillsGaps() {
        let handler = Handler.normalized(from: ["name": "", "args": ["a", 1], "id": ""])
        XCTAssertEqual(handler.name, "Untitled")
        XCTAssertEqual(handler.color, "#6b7280")
        XCTAssertEqual(handler.args, ["a", "1"])
        XCTAssertEqual(handler.id.count, 8)
        XCTAssertNil(handler.privateArgs)
        XCTAssertEqual(Handler.normalized(from: [String: Any]()).args, ["{url}"])
    }
}

final class DiscoveryTests: XCTestCase {
    func testSwatchKeepsHueWithLegibleLightness() {
        // Chrome's signed ARGB for a dark blue, 0xFF1A3A7A.
        let value = Int32(bitPattern: 0xFF1A3A7A)
        let swatch = Discovery.swatch(fromChromeColor: NSNumber(value: value))
        XCTAssertNotNil(swatch)
        XCTAssertTrue(swatch!.hasPrefix("#"))
        XCTAssertEqual(swatch!.count, 7)
        XCTAssertNil(Discovery.swatch(fromChromeColor: NSNumber(value: 0xFF808080 as UInt32))) // grey: no hue
        XCTAssertNil(Discovery.swatch(fromChromeColor: true))
        XCTAssertNil(Discovery.swatch(fromChromeColor: "blue"))
    }

    func testAppReference() {
        let chrome = Handler(name: "Chrome", command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        XCTAssertEqual(Discovery.appReference(for: chrome), .path("/Applications/Google Chrome.app"))
        let safari = Handler(name: "Safari", command: "/usr/bin/open", args: ["-a", "/Applications/Safari.app", "{url}"])
        XCTAssertEqual(Discovery.appReference(for: safari), .path("/Applications/Safari.app"))
        let named = Handler(name: "Arc", command: "/usr/bin/open", args: ["-a", "Arc", "{url}"])
        XCTAssertEqual(Discovery.appReference(for: named), .name("Arc"))
        let byId = Handler(name: "Orion", command: "/usr/bin/open", args: ["-b", "com.kagi.kagimacOS", "{url}"])
        XCTAssertEqual(Discovery.appReference(for: byId), .bundleID("com.kagi.kagimacOS"))
        XCTAssertNil(Discovery.appReference(for: Handler(name: "curl", command: "/usr/bin/curl", args: ["-O"])))
        XCTAssertNil(Discovery.appReference(for: Handler(name: "open", command: "/usr/bin/open", args: ["-a"])))
    }

    func testAppBundlePathIsOutermost() {
        XCTAssertEqual(Discovery.appBundlePath(containing:
            "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
            "/Applications/Slack.app")
        XCTAssertEqual(Discovery.appBundlePath(containing: "/Applications/Mail.app"), "/Applications/Mail.app")
        XCTAssertNil(Discovery.appBundlePath(containing: "/usr/bin/open"))
    }

    func testProfilePictureUsesLocalStateName() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
        try #"{"profile": {"info_cache": {"Profile 1": {"gaia_picture_file_name": "Me.png"}}}}"#
            .write(to: root.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
        try Data([0x89]).write(to: root.appendingPathComponent("Profile 1/Me.png"))

        let bin = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let handler = Handler(name: "Chrome — Me", command: bin, args: ["--profile-directory=Profile 1", "{url}"])
        XCTAssertEqual(Discovery.profilePicture(for: handler, home: home)?.lastPathComponent, "Me.png")

        let missing = Handler(name: "Chrome — Default", command: bin, args: ["--profile-directory=Default", "{url}"])
        XCTAssertNil(Discovery.profilePicture(for: missing, home: home))
        let escaping = Handler(name: "Chrome — ..", command: bin, args: ["--profile-directory=..", "{url}"])
        XCTAssertNil(Discovery.profilePicture(for: escaping, home: home))
        XCTAssertNil(Discovery.profilePicture(for: Handler(name: "Firefox", command: "/firefox"), home: home))
    }

    func testHslMatchesJavaScript() {
        // Values from handlers.js' hslToHex for the same inputs.
        XCTAssertEqual(Discovery.hslToHex(0, 0.62, 0.58), "#d65151")
        XCTAssertEqual(Discovery.hslToHex(210, 0.62, 0.58), "#5194d6")
    }
}

final class ConfigTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadsElectronConfigAndRoundTrips() throws {
        let file = dir.appendingPathComponent("handlers.json")
        try """
        {
          "handlers": [
            {"id": "a1", "name": "Chrome — Work", "subtitle": "me@example.com", "color": "#51bed6",
             "command": "/chrome", "args": ["--profile-directory=Default", "{url}"]},
            {"id": "b2", "name": "Firefox", "command": "/firefox", "args": ["{url}"], "privateArgs": ["-private-window"]}
          ],
          "rules": {"www.github.com": "a1", "orphan.com": "zz"},
          "copyOnOpen": true
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let config = Config(file: file, discover: { XCTFail("should not rediscover"); return [] })
        XCTAssertEqual(config.data.handlers.count, 2)
        XCTAssertEqual(config.data.rules, ["github.com": "a1"])
        XCTAssertTrue(config.data.copyOnOpen)
        XCTAssertFalse(config.data.doorbell)
        XCTAssertFalse(config.data.pageTitles, "page titles are opt-in")
        XCTAssertTrue(config.data.menuBar, "absent menuBar means on")
        XCTAssertEqual(config.data.appearance, .system, "absent appearance follows the system")
        XCTAssertEqual(config.data.pickerPlacement, .window, "absent placement centers on the front window")
        XCTAssertEqual(config.data.handlers[1].privateArgs, ["-private-window"])
        XCTAssertEqual(config.handlerId(forHost: "gist.github.com"), "a1")

        config.setMenuBar(false)
        config.setAppearance(.dark)
        config.setPickerPlacement(.pointer)
        let reread = Config(file: file, discover: { [] })
        XCTAssertEqual(reread.data, config.data)
        XCTAssertFalse(reread.data.menuBar)
        XCTAssertEqual(reread.data.appearance, .dark)
        XCTAssertEqual(reread.data.pickerPlacement, .pointer)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\"appearance\" : \"dark\""))
    }

    func testSourceRulesApplyWhenNoDomainRuleDoes() {
        let file = dir.appendingPathComponent("handlers.json")
        let config = Config(file: file, discover: {
            [Handler(id: "work", name: "Work", command: "/w"), Handler(id: "home", name: "Home", command: "/h")]
        })
        config.setRule(host: "youtube.com", handlerId: "home")
        config.setSourceRule(bundleID: "com.tinyspeck.slackmacgap", handlerId: "work")

        XCTAssertEqual(config.handlerId(forHost: "github.com", source: "com.tinyspeck.slackmacgap"), "work")
        XCTAssertEqual(config.handlerId(forHost: "github.com", source: "COM.TinySpeck.SlackMacGap"), "work")
        // The saved domain is the more specific choice.
        XCTAssertEqual(config.handlerId(forHost: "www.youtube.com", source: "com.tinyspeck.slackmacgap"), "home")
        XCTAssertNil(config.handlerId(forHost: "github.com", source: "com.apple.mail"))
        XCTAssertNil(config.handlerId(forHost: "github.com"))

        // Saving again under another case replaces, rather than duplicates.
        config.setSourceRule(bundleID: "COM.TINYSPECK.SLACKMACGAP", handlerId: "home")
        XCTAssertEqual(config.data.sourceRules, ["COM.TINYSPECK.SLACKMACGAP": "home"])

        XCTAssertEqual(config.sourcesLost(with: [Handler(id: "work", name: "Work", command: "/w")]),
                       ["COM.TINYSPECK.SLACKMACGAP"])
        config.replaceHandlers([Handler(id: "work", name: "Work", command: "/w")])
        XCTAssertEqual(config.data.sourceRules, [:], "a removed handler takes its app rules with it")

        config.setSourceRule(bundleID: "com.apple.mail", handlerId: "work")
        let reread = Config(file: file, discover: { [] })
        XCTAssertEqual(reread.data.sourceRules, ["com.apple.mail": "work"])
    }

    func testSourceRulesPruneOnLoad() throws {
        let file = dir.appendingPathComponent("handlers.json")
        try #"{"handlers": [{"id": "a", "name": "A", "command": "/a"}], "sourceRules": {"com.x": "a", "com.gone": "z", " ": "a", "com.bad": 1}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config(file: file, discover: { [] }).data.sourceRules, ["com.x": "a"])
    }

    func testUnknownAppearanceFollowsSystem() throws {
        let file = dir.appendingPathComponent("handlers.json")
        try #"{"handlers": [], "appearance": "sepia"}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config(file: file, discover: { [] }).data.appearance, .system)
    }

    func testMissingFileDiscoversAndWrites() {
        let file = dir.appendingPathComponent("sub/handlers.json")
        let config = Config(file: file, discover: { [Handler(id: "x", name: "X", command: "/x")] })
        XCTAssertEqual(config.data.handlers.map(\.id), ["x"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRediscoverForgetsOnlyLostDomains() {
        let file = dir.appendingPathComponent("handlers.json")
        var next: [Handler] = [
            Handler(id: "a", name: "A", command: "/a"),
            Handler(id: "b", name: "B", command: "/b"),
        ]
        let config = Config(file: file, discover: { next })
        config.setRule(host: "a.com", handlerId: "a")
        config.setRule(host: "b.com", handlerId: "b")

        next = [Handler(id: "fresh", name: "A again", command: "/a")]
        let handlers = config.nextHandlers()
        XCTAssertEqual(config.domainsLost(with: handlers), ["b.com"])
        config.rediscover(handlers)
        XCTAssertEqual(config.data.rules, ["a.com": "a"])
        XCTAssertEqual(config.data.handlers.map(\.name), ["A again"])
    }
}

final class LinkExtractorTests: XCTestCase {
    func testFindsWebLinksInOrderWithoutRepeats() {
        let text = """
        See https://github.com/fleetio/app/pull/12, and also github.com/fleetio or
        www.example.com/docs?x=1. Mail me at someone@example.com, ftp://files.example.com
        is out, and https://github.com/fleetio/app/pull/12 again.
        """
        XCTAssertEqual(LinkExtractor.urls(in: text), [
            "https://github.com/fleetio/app/pull/12",
            "http://github.com/fleetio",
            "http://www.example.com/docs?x=1",
        ])
    }

    func testNothingToFind() {
        XCTAssertEqual(LinkExtractor.urls(in: "just words, no links"), [])
        XCTAssertEqual(LinkExtractor.urls(in: ""), [])
    }

    func testCapsTheCount() {
        let text = (1...50).map { "https://site\($0).example.com" }.joined(separator: " ")
        XCTAssertEqual(LinkExtractor.urls(in: text).count, LinkExtractor.limit)
    }
}

final class TitleParsingTests: XCTestCase {
    func testTitleTagDecodedAndTidied() {
        let html = "<html><head><TITLE lang=en>\n  Penguin &#8211; Wikipedia &amp; more &hellip;\n</TITLE></head>"
        XCTAssertEqual(TitleParsing.title(fromHTML: html), "Penguin – Wikipedia & more …")
    }

    func testFallsBackToOpenGraph() {
        let html = #"<head><title>  </title><meta content="Pull &quot;12&quot; &#x2014; fix" property="og:title"></head>"#
        XCTAssertEqual(TitleParsing.title(fromHTML: html), "Pull \"12\" — fix")
    }

    func testNoTitle() {
        XCTAssertNil(TitleParsing.title(fromHTML: "<html><body>hi</body></html>"))
    }

    func testLongTitlesAreCut() {
        let title = TitleParsing.title(fromHTML: "<title>" + String(repeating: "a", count: 400) + "</title>")!
        XCTAssertEqual(title.count, TitleParsing.maxLength)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testUnknownEntitiesLeftAlone() {
        XCTAssertEqual(TitleParsing.decodeEntities("a &bogus; b &#65;"), "a &bogus; b A")
    }
}

final class FaviconParsingTests: XCTestCase {
    func testSafeDomain() {
        XCTAssertTrue(FaviconParsing.isSafeDomain("docs.example.com"))
        XCTAssertFalse(FaviconParsing.isSafeDomain("../etc"))
        XCTAssertFalse(FaviconParsing.isSafeDomain("Example.com"))
        XCTAssertFalse(FaviconParsing.isSafeDomain(""))
    }

    func testSniff() {
        XCTAssertEqual(FaviconParsing.sniff(Data([0x89, 0x50, 0x4e, 0x47, 0x0d])), "png")
        XCTAssertEqual(FaviconParsing.sniff(Data([0, 0, 1, 0, 1])), "ico")
        XCTAssertEqual(FaviconParsing.sniff(Data([0xff, 0xd8, 0xff, 0xe0])), "jpg")
        XCTAssertEqual(FaviconParsing.sniff(Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(FaviconParsing.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "webp")
        XCTAssertEqual(FaviconParsing.sniff(Data("\n <?xml version='1.0'?><svg></svg>".utf8)), "svg")
        XCTAssertNil(FaviconParsing.sniff(Data("<!doctype html><html>".utf8)))
    }

    func testIconLinksRankedForSmallDisplay() {
        let html = """
        <link rel="apple-touch-icon" href="/apple.png">
        <link rel="icon" href="/big.png" sizes="192x192">
        <LINK REL='icon' href='/mark.svg'>
        <link rel="shortcut icon" href="https://cdn.example.com/32.png" sizes="32x32">
        <link rel="stylesheet" href="/site.css">
        <link rel="icon" href="javascript:alert(1)">
        """
        let links = FaviconParsing.iconLinks(html: html, base: URL(string: "https://example.com/start")!)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://cdn.example.com/32.png",
            "https://example.com/mark.svg",
            "https://example.com/big.png",
            "https://example.com/apple.png",
        ])
    }
}
