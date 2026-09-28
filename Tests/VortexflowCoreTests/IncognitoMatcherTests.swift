import CoreGraphics
import Testing
@testable import VortexflowCore

/// Pairing a browser's own view of its windows with the window server's.
///
/// The interesting cases are all ambiguity. Neither the title nor the rectangle identifies a
/// window on its own — two blank tabs share a title, and on a laptop where everything is
/// maximised, windows share a rectangle to the pixel — so what matters is which pairs get settled
/// first and what happens when nothing can be settled at all.
@Suite("Incognito matching")
struct IncognitoMatcherTests {

    private static let chrome = "com.google.Chrome"

    private func entry(
        id: CGWindowID,
        title: String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800),
        bundle: String? = IncognitoMatcherTests.chrome,
        pid: pid_t = 1
    ) -> WindowEntry {
        var entry = Fixture.entry(
            id: id,
            app: "Google Chrome",
            title: title,
            pid: pid,
            frame: frame
        )
        entry.bundleIdentifier = bundle
        return entry
    }

    private func scripted(
        _ identifier: Int,
        incognito: Bool,
        title: String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800),
        browser: BrowserTab.Browser = .chrome
    ) -> ScriptedBrowserWindow {
        ScriptedBrowserWindow(
            browser: browser,
            identifier: identifier,
            isIncognito: incognito,
            title: title,
            frame: frame
        )
    }

    @Test("A window matched to an incognito one is badged, and its neighbours are not")
    func matchesByTitle() {
        let entries = [
            entry(id: 1, title: "Inbox — Mail"),
            entry(id: 2, title: "New Incognito Tab"),
            entry(id: 3, title: "Artificial Analysis"),
        ]
        let scripted = [
            self.scripted(10, incognito: false, title: "Inbox — Mail"),
            self.scripted(11, incognito: true, title: "New Incognito Tab"),
            self.scripted(12, incognito: false, title: "Artificial Analysis"),
        ]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted) == [2])
    }

    /// The case that made the rectangle unusable as a primary key: on a laptop, every window is
    /// the same size, so geometry cannot tell an incognito window from a normal one.
    @Test("Identical rectangles are resolved by title")
    func identicalFramesResolvedByTitle() {
        let shared = CGRect(x: -1512, y: 68, width: 1512, height: 914)
        let entries = [
            entry(id: 1, title: "Artificial Analysis", frame: shared),
            entry(id: 2, title: "New Incognito Tab", frame: shared),
        ]
        let scripted = [
            self.scripted(10, incognito: true, title: "New Incognito Tab", frame: shared),
            self.scripted(11, incognito: false, title: "Artificial Analysis", frame: shared),
        ]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted) == [2])
    }

    /// The mirror case: two windows share a title, and only the rectangle separates them. The
    /// strongest pass settles the one that agrees on both before the weaker passes guess.
    @Test("A shared title is resolved by the rectangle")
    func sharedTitleResolvedByFrame() {
        let entries = [
            entry(id: 1, title: "New Tab", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            entry(id: 2, title: "New Tab", frame: CGRect(x: 900, y: 0, width: 700, height: 500)),
        ]
        let scripted = [
            self.scripted(
                10,
                incognito: true,
                title: "New Tab",
                frame: CGRect(x: 900, y: 0, width: 700, height: 500)
            ),
            self.scripted(
                11,
                incognito: false,
                title: "New Tab",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
        ]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted) == [2])
    }

    /// Rounding between the two APIs must not break a pair.
    @Test("Rectangles within tolerance still match")
    func frameToleranceAbsorbsRounding() {
        let entries = [entry(id: 1, title: "", frame: CGRect(x: 10, y: 10, width: 800, height: 600))]
        let scripted = [
            self.scripted(
                10,
                incognito: true,
                title: "different",
                frame: CGRect(x: 11, y: 9, width: 801, height: 599)
            )
        ]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted) == [1])
    }

    /// Unknown means normal. Badging a window the browser never confirmed would tell the user
    /// something false about their privacy, which is worse than telling them nothing.
    @Test("A window that cannot be matched is not badged")
    func unmatchedWindowsAreNotBadged() {
        let entries = [entry(id: 1, title: "Something else", frame: CGRect(x: 5, y: 5, width: 10, height: 10))]
        let scripted = [
            self.scripted(
                10,
                incognito: true,
                title: "Nothing like it",
                frame: CGRect(x: 900, y: 900, width: 400, height: 400)
            )
        ]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted).isEmpty)
    }

    /// An empty title is not evidence — every untitled window would otherwise match every other.
    @Test("Empty titles do not match each other")
    func emptyTitlesAreNotEvidence() {
        let entries = [entry(id: 1, title: "", frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        let scripted = [
            self.scripted(
                10,
                incognito: true,
                title: "",
                frame: CGRect(x: 500, y: 500, width: 900, height: 900)
            )
        ]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted).isEmpty)
    }

    @Test("Windows of other applications are never badged")
    func otherApplicationsAreIgnored() {
        let entries = [
            entry(id: 1, title: "New Incognito Tab", bundle: "com.apple.Safari"),
            entry(id: 2, title: "New Incognito Tab", bundle: nil),
        ]
        let scripted = [self.scripted(10, incognito: true, title: "New Incognito Tab")]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted).isEmpty)
    }

    /// A tab entry has no window of its own — `windowID` is zero for all of them — so it must
    /// never be paired with one.
    @Test("Tab entries are never badged")
    func tabsAreIgnored() {
        let tab = BrowserTab(
            browser: .chrome,
            windowIdentifier: 10,
            tabIndex: 1,
            title: "New Incognito Tab",
            url: "https://example.com"
        )
        var entry = WindowEntry.tabEntry(tab, application: nil)
        entry.bundleIdentifier = Self.chrome

        let scripted = [self.scripted(10, incognito: true, title: "New Incognito Tab", frame: .zero)]

        #expect(IncognitoMatcher.incognitoWindowIDs(entries: [entry], scripted: scripted).isEmpty)
    }

    @Test("Nothing scripted means nothing badged")
    func noScriptedWindowsMeansNoBadges() {
        let entries = [entry(id: 1, title: "New Incognito Tab")]
        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: []).isEmpty)
    }

    /// One scripted window that fits two native entries does not identify either one. Guessing by
    /// array order could put a private badge or active-tab favicon on the wrong window.
    @Test("An ambiguous scripted window is not guessed")
    func ambiguousScriptedWindowIsNotGuessed() {
        let shared = CGRect(x: 0, y: 0, width: 900, height: 700)
        let entries = [
            entry(id: 1, title: "New Tab", frame: shared),
            entry(id: 2, title: "New Tab", frame: shared),
        ]
        let scripted = [self.scripted(10, incognito: true, title: "New Tab", frame: shared)]

        let badged = IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted)
        #expect(badged.isEmpty)
    }

    // MARK: - Building a record from what the browser said

    private static let chromeProcess = BrowserTabService.BrowserProcess(
        browser: .chrome,
        processIdentifier: 855
    )

    @Test("A window listing becomes a record with its mode and rectangle")
    func buildsWindowRecord() {
        let normal = BrowserTabService.window(
            from: BrowserTabService.Session.WindowListing(
                identifier: 1_263_772_735,
                mode: "normal",
                title: "Inbox",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1044),
                activeTabURL: "https://mail.example/"
            ),
            of: Self.chromeProcess
        )
        #expect(normal.identifier == 1_263_772_735)
        #expect(!normal.isIncognito)
        #expect(normal.allowsFaviconRequest)
        #expect(normal.activeTabURL == "https://mail.example/")
        #expect(normal.title == "Inbox")
        #expect(normal.frame == CGRect(x: 0, y: 0, width: 1920, height: 1044))
        #expect(normal.processIdentifier == 855)

        let private_ = BrowserTabService.window(
            from: BrowserTabService.Session.WindowListing(
                identifier: 1_263_773_420,
                mode: "incognito",
                title: "New Incognito tab",
                frame: CGRect(x: -1512, y: 68, width: 1512, height: 914)
            ),
            of: Self.chromeProcess
        )
        #expect(private_.isIncognito)
        #expect(!private_.allowsFaviconRequest)
        #expect(private_.activeTabURL == nil)
        #expect(private_.frame == CGRect(x: -1512, y: 68, width: 1512, height: 914))
    }

    /// An unrecognised mode stays visually unbadged, but cannot authorize a favicon request.
    @Test("An unknown mode is unbadged and network-ineligible")
    func unknownModeFailsClosed() {
        let window = BrowserTabService.window(
            from: BrowserTabService.Session.WindowListing(
                identifier: 9,
                mode: "guest",
                title: "Window",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            of: Self.chromeProcess
        )
        #expect(!window.isIncognito)
        #expect(!window.allowsFaviconRequest)
    }

    /// A window whose geometry never arrived is still usable for mode and title; only the frame
    /// pass of the matcher loses its evidence.
    @Test("A listing with no rectangle still becomes a record")
    func missingGeometryStillBuilds() {
        let window = BrowserTabService.window(
            from: BrowserTabService.Session.WindowListing(
                identifier: 8,
                mode: "incognito",
                title: "Good"
            ),
            of: Self.chromeProcess
        )
        #expect(window.identifier == 8)
        #expect(window.isIncognito)
        #expect(window.frame == .zero)
    }

    /// An empty active-tab address is dropped rather than carried as a URL, because the favicon
    /// loader treats "present" as "worth requesting".
    @Test("An empty active address is not carried")
    func emptyActiveAddressIsDropped() {
        let window = BrowserTabService.window(
            from: BrowserTabService.Session.WindowListing(
                identifier: 3,
                mode: "normal",
                activeTabURL: ""
            ),
            of: Self.chromeProcess
        )
        #expect(window.activeTabURL == nil)
    }

    /// Two instances of one browser each have their own windows, and their window ids come from
    /// separate counters. Pairing has to stay inside the process, or a card can be told it is
    /// private because the *other* Chrome has an incognito window.
    @Test("A window is never paired across processes")
    func pairingStaysWithinTheProcess() {
        let shared = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let mine = entry(id: 4242, title: "Mahesh Auti", frame: shared, pid: 855)

        let otherInstance = ScriptedBrowserWindow(
            browser: .chrome,
            processIdentifier: 37_835,
            identifier: 943_944_415,
            isIncognito: true,
            title: "Mahesh Auti",
            frame: shared
        )

        #expect(
            IncognitoMatcher.incognitoWindowIDs(entries: [mine], scripted: [otherInstance]).isEmpty,
            "another instance's incognito window must not badge this one"
        )

        let sameInstance = ScriptedBrowserWindow(
            browser: .chrome,
            processIdentifier: 855,
            identifier: 1_263_791_277,
            isIncognito: true,
            title: "Mahesh Auti",
            frame: shared
        )
        #expect(
            IncognitoMatcher.incognitoWindowIDs(entries: [mine], scripted: [sameInstance]) == [4242]
        )
    }

    /// Safari has no `mode`, so it is never asked and never badged. Terminal has no browsing
    /// mode either; it is inspected only so its windows can be paired for tab search.
    @Test("Only Chromium browsers report a window mode")
    func onlyChromiumReportsMode() {
        #expect(!BrowserTab.Browser.safari.reportsWindowMode)
        #expect(!BrowserTab.Browser.terminal.reportsWindowMode)
        for browser in BrowserTab.Browser.allCases
            where browser != .safari && browser != .terminal
        {
            #expect(browser.reportsWindowMode, "\(browser) should report a mode")
        }
    }

    // MARK: - Titles the two APIs report differently

    /// The exact shape that shipped broken, transcribed from a real session.
    ///
    /// Two maximised Chrome windows, one private. Their rectangles are identical to the pixel, so
    /// the frame pass cannot separate them. Accessibility reports the page title with Chrome's name
    /// and the localised mode appended — 58 characters arriving as 86 — while Chrome's own scripting
    /// name for the other window is elided in the middle at 59 characters. Exact equality matched
    /// neither, the frame pass could settle neither, and both windows went unclassified: the private
    /// one showed no badge at all.
    @Test("a private window is found when the browser and Accessibility word its title differently")
    func matchesDespiteTitleDecorationAndElision() {
        let shared = CGRect(x: -1512, y: 68, width: 1512, height: 950)
        let entries = [
            entry(
                id: 5164,
                title: "[development] Quattr Inc | Grow Your Web Traffic 2X Faster"
                    + " - Google Chrome (Incognito)",
                frame: shared
            ),
            entry(
                id: 54,
                title: "fix(clustering): make the string comparison deterministic"
                    + " by mahesha-quattr · Pull Request #91 · Quattr/taxonomy-engine"
                    + " - Google Chrome",
                frame: shared
            ),
        ]
        let scripted = [
            self.scripted(
                1_263_774_572,
                incognito: true,
                title: "[development] Quattr Inc | Grow Your Web Traffic 2X Faster",
                frame: shared
            ),
            self.scripted(
                1_263_774_200,
                incognito: false,
                title: "fix(clustering): make the str… #91 · Quattr/taxonomy-engine",
                frame: shared
            ),
        ]

        let matched = IncognitoMatcher.matchedWindows(entries: entries, scripted: scripted)
        #expect(matched.count == 2)
        #expect(matched[5164]?.identifier == 1_263_774_572)
        #expect(matched[54]?.identifier == 1_263_774_200)
        #expect(IncognitoMatcher.incognitoWindowIDs(entries: entries, scripted: scripted) == [5164])
    }

    /// Containment must not outrank equality. When one window's title is a substring of another's,
    /// the window whose title matches exactly has to win, whichever order they arrive in.
    @Test("an exact title beats a merely contained one")
    func exactTitleWinsOverContainment() {
        let entries = [
            entry(id: 1, title: "Docs", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            entry(id: 2, title: "Docs — Reference", frame: CGRect(x: 10, y: 0, width: 800, height: 600)),
        ]
        let scripted = [
            self.scripted(10, incognito: true, title: "Docs",
                          frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            self.scripted(11, incognito: false, title: "Docs — Reference",
                          frame: CGRect(x: 10, y: 0, width: 800, height: 600)),
        ]

        let matched = IncognitoMatcher.matchedWindows(entries: entries, scripted: scripted)
        #expect(matched[1]?.identifier == 10)
        #expect(matched[2]?.identifier == 11)
    }

    /// A fragment short enough to appear in anything is not evidence. Without a floor here, a
    /// browser reporting a near-empty title would pair with an arbitrary window.
    ///
    /// The rectangles are deliberately different. With them equal the `frame` pass settles the pair
    /// on its own and the title rule is never consulted, so the test would pass without testing
    /// anything — which is exactly what it did on the first run.
    @Test("a title too short to mean anything does not pair by containment")
    func shortTitleDoesNotPairByContainment() {
        let entries = [
            entry(
                id: 1,
                title: "A really quite long window title - Google Chrome",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
        ]
        let scripted = [
            self.scripted(
                10,
                incognito: true,
                title: "e",
                frame: CGRect(x: 900, y: 0, width: 800, height: 600)
            ),
        ]

        #expect(IncognitoMatcher.matchedWindows(entries: entries, scripted: scripted).isEmpty)
    }

    /// Fragments either side of an elision must appear in the order the browser reported them, so
    /// that a title sharing both fragments in reverse is not accepted. Distinct rectangles again,
    /// so the frame pass cannot settle the pair behind the rule under test.
    @Test("elided fragments must appear in order")
    func elidedFragmentsMustBeInOrder() {
        let entries = [
            entry(
                id: 1,
                title: "taxonomy-engine and then clustering - Google Chrome",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
        ]
        let scripted = [
            self.scripted(
                10,
                incognito: true,
                title: "clustering… taxonomy-engine",
                frame: CGRect(x: 900, y: 0, width: 800, height: 600)
            ),
        ]

        #expect(IncognitoMatcher.matchedWindows(entries: entries, scripted: scripted).isEmpty)
    }

    /// Containment is theirs-inside-ours only. Accessibility is the side that adds decoration, so
    /// accepting the reverse would let a browser record claim a window with a longer title than it
    /// reported — and on a desktop full of maximised windows, claim the wrong one.
    @Test("containment does not run in reverse")
    func containmentIsNotSymmetric() {
        let entries = [
            entry(id: 1, title: "Quattr", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ]
        let scripted = [
            self.scripted(10, incognito: true, title: "Quattr Inc | Grow Your Web Traffic",
                          frame: CGRect(x: 400, y: 0, width: 800, height: 600)),
        ]

        #expect(IncognitoMatcher.matchedWindows(entries: entries, scripted: scripted).isEmpty)
    }
}
