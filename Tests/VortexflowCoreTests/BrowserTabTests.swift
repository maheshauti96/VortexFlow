import CoreGraphics
import Testing
@testable import VortexflowCore

/// Searching browser tabs.
///
/// The point of the feature is that a tab you cannot see — not the active tab, maybe not
/// even the front window — is findable by name. So the tests are about it being reachable
/// through search, ranked sensibly, and kept out of the way otherwise.
@Suite("Browser tabs")
struct BrowserTabTests {

    private func tab(
        _ browser: BrowserTab.Browser = .chrome,
        window: Int = 1,
        index: Int,
        title: String,
        url: String
    ) -> BrowserTab {
        BrowserTab(
            browser: browser,
            windowIdentifier: window,
            tabIndex: index,
            title: title,
            url: url
        )
    }

    private func entry(_ tab: BrowserTab) -> WindowEntry {
        WindowEntry.tabEntry(tab, application: nil)
    }

    /// Taken from a live Chrome session, including the awkward parts: a tab whose title
    /// says nothing about its address, and two tabs sharing one.
    private var chromeTabs: [WindowEntry] {
        [
            entry(tab(index: 1, title: "OpenMausBot: Your own team of AI bots", url: "https://www.openmausbot.com/#pricing")),
            entry(tab(index: 2, title: "taxonomy engine - Grok", url: "https://grok.com/c/01b2e981?rid=d283ef")),
            entry(tab(index: 3, title: "YouTube", url: "https://www.youtube.com/")),
            entry(tab(window: 2, index: 4, title: "Explore Opportunities | Mercor", url: "https://work.mercor.com/explore")),
        ]
    }

    // MARK: - Identity

    /// Every tab in a window would share the window's `CGWindowID`, so identity cannot come
    /// from there — two tabs colliding would break the card list and the hit-test mapping.
    @Test("Tabs are distinguishable from each other and from windows")
    func tabsHaveDistinctIdentities() {
        let entries = chromeTabs
        let identities = Set(entries.map(\.id))
        #expect(identities.count == entries.count)

        for entry in entries {
            #expect(entry.isTab)
            // No window identity, so the window-shaped machinery skips them.
            #expect(entry.windowID == 0)
            #expect(entry.axElement == nil)
        }

        let window = Fixture.entry(id: 1, app: "Google Chrome")
        #expect(!window.isTab)
        #expect(window.id != entries[0].id)
    }

    @Test("A tab shows its own title, falling back to its host")
    func tabTitleFallsBackToHost() {
        #expect(entry(tab(index: 1, title: "taxonomy engine - Grok", url: "https://grok.com/c/1")).displayTitle
            == "taxonomy engine - Grok")
        // A tab still loading has no title yet.
        #expect(entry(tab(index: 1, title: "", url: "https://grok.com/c/1")).displayTitle == "grok.com")
    }

    @Test("The host is the readable part of a URL")
    func hostIsTheReadablePart() {
        #expect(tab(index: 1, title: "", url: "https://grok.com/c/01b2?rid=x").host == "grok.com")
        // "www." carries no information and costs card width.
        #expect(tab(index: 1, title: "", url: "https://www.youtube.com/").host == "youtube.com")
        #expect(tab(index: 1, title: "", url: "http://localhost:3000/explorer").host == "localhost")
    }

    // MARK: - Search

    /// The case that prompted the feature: "grok" should find the Grok tab even though its
    /// title never begins with it and the tab is not the active one.
    @Test("Typing a site name finds the tab")
    func typingSiteNameFindsTheTab() {
        let results = WindowSearch.filter(chromeTabs, query: "grok")
        #expect(results.count == 1)
        #expect(results.first?.tab?.host == "grok.com")
        #expect(results.first?.tab?.tabIndex == 2)
    }

    /// A host match has to rank at least as highly as a title match, because the address is
    /// usually what the user remembers.
    @Test("A host match outranks an incidental title mention")
    func hostMatchOutranksTitleMention() {
        let entries = [
            entry(tab(index: 1, title: "Alternative to Grok Bot", url: "https://github.com/openmaus")),
            entry(tab(index: 2, title: "taxonomy engine", url: "https://grok.com/c/1")),
        ]
        let results = WindowSearch.filter(entries, query: "grok")
        #expect(results.count == 2)
        #expect(results.first?.tab?.host == "grok.com")
    }

    @Test("Tab titles are searchable too")
    func tabTitlesAreSearchable() {
        #expect(WindowSearch.filter(chromeTabs, query: "mercor").count == 1)
        #expect(WindowSearch.filter(chromeTabs, query: "youtube").count == 1)
    }

    /// The reported miss: the title is "FlowTrackr" and the host is github.io, but
    /// the path is `/workday-task-board/`. Matching only the domain would offer the web
    /// instead of the tab that is already open.
    @Test("A word in the URL path finds the tab")
    func aPathWordFindsTheTab() {
        let tabs = [
            entry(tab(
                index: 1,
                title: "FlowTrackr",
                url: "https://mahesha-quattr.github.io/workday-task-board/"
            )),
            entry(tab(index: 2, title: "Grok", url: "https://grok.com/c/1")),
        ]
        let results = WindowSearch.filter(tabs, query: "workday")
        #expect(results.count == 1)
        #expect(results.first?.displayTitle == "FlowTrackr")
    }

    /// Query strings and the scheme are not memorable and would match almost everything.
    @Test("A query string or scheme is not searchable")
    func queryStringAndSchemeAreNotSearchable() {
        let tabs = [
            entry(tab(index: 1, title: "Grok", url: "https://grok.com/c/1?rid=workday-token")),
        ]
        #expect(WindowSearch.filter(tabs, query: "workday").isEmpty)
        #expect(WindowSearch.filter(tabs, query: "https").isEmpty)
    }

    @Test("A query matching no tab returns none")
    func nonMatchingQueryReturnsNoTabs() {
        #expect(WindowSearch.filter(chromeTabs, query: "zzzz").isEmpty)
    }

    // MARK: - State integration

    /// Tabs must not appear until asked for. A browser with forty tabs would otherwise bury
    /// every real window in the switcher.
    @Test("Tabs stay out of the default list")
    @MainActor
    func tabsStayOutOfTheDefaultList() {
        let state = OverlayState()
        state.load(
            entries: [Fixture.entry(id: 1, app: "Google Chrome"), Fixture.entry(id: 2, app: "Slack")],
            selectedIndex: 0
        )
        #expect(!state.hasLoadedTabs)

        state.setTabs(chromeTabs)
        #expect(state.hasLoadedTabs)
        // Loaded, but not shown: no query is active.
        #expect(state.entries.count == 2)
        #expect(state.entries.allSatisfy { !$0.isTab })
    }

    @Test("Typing brings matching tabs into the results")
    @MainActor
    func typingBringsTabsIntoResults() {
        let state = OverlayState()
        state.load(entries: [Fixture.entry(id: 1, app: "Slack", title: "#peek-dev")], selectedIndex: 0)
        state.setTabs(chromeTabs)

        #expect(state.appendToSearch("grok"))
        #expect(state.localEntries.count == 1)
        #expect(state.entries.first?.isTab == true)
        #expect(state.selectedIndex == 0)
        #expect(state.selectedEntry?.tab?.host == "grok.com")
    }

    /// Tabs arriving asynchronously must fold into a query the user has already typed,
    /// rather than being ignored because the search ran before they loaded.
    @Test("Tabs loaded after typing still join the results")
    @MainActor
    func tabsLoadedAfterTypingJoinResults() {
        let state = OverlayState()
        state.load(entries: [Fixture.entry(id: 1, app: "Slack")], selectedIndex: 0)

        state.appendToSearch("grok")
        #expect(state.entries.isEmpty)

        // The browsers answer a moment later.
        #expect(state.setTabs(chromeTabs))
        #expect(state.localEntries.count == 1)
        #expect(state.entries.first?.tab?.host == "grok.com")
    }

    /// A real window should win a tie against a tab: switching windows is the primary job.
    @Test("A window outranks a tab that scores the same")
    @MainActor
    func windowOutranksEquallyScoringTab() {
        let state = OverlayState()
        state.load(entries: [Fixture.entry(id: 1, app: "Grok Bot", title: "Grok Bot")], selectedIndex: 0)
        state.setTabs(chromeTabs)

        state.appendToSearch("grok")
        #expect(state.localEntries.count == 2)
        #expect(state.entries.first?.isTab == false)
        #expect(state.localEntries.last?.isTab == true)
    }

    @Test("Clearing the search puts the tabs away again")
    @MainActor
    func clearingSearchPutsTabsAway() {
        let state = OverlayState()
        state.load(entries: [Fixture.entry(id: 1, app: "Slack")], selectedIndex: 0)
        state.setTabs(chromeTabs)
        state.appendToSearch("grok")
        #expect(state.entries.first?.isTab == true)

        state.clearSearch()
        #expect(state.entries.count == 1)
        #expect(state.entries.allSatisfy { !$0.isTab })
    }

    /// A new presentation re-enumerates, so stale tabs from the last one must not linger.
    @Test("A new presentation forgets the previous tabs")
    @MainActor
    func newPresentationForgetsTabs() {
        let state = OverlayState()
        state.load(entries: [Fixture.entry(id: 1, app: "Slack")], selectedIndex: 0)
        state.setTabs(chromeTabs)
        #expect(state.hasLoadedTabs)

        state.load(entries: [Fixture.entry(id: 1, app: "Slack")], selectedIndex: 0)
        #expect(!state.hasLoadedTabs)

        state.appendToSearch("grok")
        #expect(state.entries.isEmpty)
    }

    /// A tab cannot be closed from the switcher, so the affordance must not be offered —
    /// otherwise clicking it would close the browser window instead.
    @Test("Tabs offer no close button")
    @MainActor
    func tabsOfferNoCloseButton() {
        let state = OverlayState()
        state.canCloseWindows = true
        state.load(entries: [Fixture.entry(id: 1, app: "Slack")], selectedIndex: 0)
        state.setTabs(chromeTabs)
        state.appendToSearch("grok")

        for entry in state.entries {
            #expect(!state.canClose(entry))
        }
    }

    // MARK: - Browser support

    @Test("Every supported browser is addressable")
    func everyBrowserIsAddressable() {
        for browser in BrowserTab.Browser.allCases {
            #expect(!browser.bundleIdentifier.isEmpty)
            #expect(!browser.scriptingName.isEmpty)
            #expect(browser.bundleIdentifier.contains("."))
        }
        let identifiers = Set(BrowserTab.Browser.allCases.map(\.bundleIdentifier))
        #expect(identifiers.count == BrowserTab.Browser.allCases.count)
    }

    /// Safari's scripting vocabulary differs from Chrome's, and using the wrong term fails
    /// at runtime rather than at compile time.
    @Test("Safari uses its own scripting terms")
    func safariUsesItsOwnTerms() {
        #expect(BrowserTab.Browser.safari.titleProperty == "name")
        #expect(BrowserTab.Browser.safari.usesCurrentTab)
        #expect(!BrowserTab.Browser.safari.usesSelectedTab)

        for browser in BrowserTab.Browser.allCases
            where browser != .safari && browser != .terminal
        {
            #expect(browser.titleProperty == "title")
            #expect(!browser.usesCurrentTab)
            #expect(!browser.usesSelectedTab)
            #expect(browser.hasTabURLs)
        }
    }

    /// Terminal's dictionary is a third vocabulary: no tab `name`, no URL, and selection is
    /// a boolean on the tab rather than an index on the window.
    ///
    /// The title term is the Cocoa selector, not the AppleScript spelling: Scripting Bridge
    /// sends `customTitle`, and `custom title` names nothing.
    @Test("Terminal uses its own scripting terms")
    func terminalUsesItsOwnTerms() {
        let terminal = BrowserTab.Browser.terminal
        #expect(terminal.bundleIdentifier == "com.apple.Terminal")
        #expect(terminal.scriptingName == "Terminal")
        #expect(terminal.titleProperty == "customTitle")
        #expect(terminal.usesSelectedTab)
        #expect(!terminal.usesCurrentTab)
        #expect(!terminal.hasTabURLs)
        #expect(!terminal.reportsWindowMode)
        #expect(terminal.needsWindowInspection)
    }



    // MARK: - Building tabs from what a window answered

    private static let chromeProcess = BrowserTabService.BrowserProcess(
        browser: .chrome,
        processIdentifier: 855
    )

    private func listing(
        window: Int,
        mode: String = "normal",
        titles: [String],
        urls: [String],
        frame: CGRect? = nil
    ) -> BrowserTabService.Session.WindowListing {
        BrowserTabService.Session.WindowListing(
            identifier: window,
            mode: mode,
            frame: frame,
            titles: titles,
            urls: urls
        )
    }

    @Test("A window's tab lists become tabs carrying their window's mode")
    func windowListingsBecomeTabs() {
        let tabs = BrowserTabService.tabs(
            in: [
                listing(
                    window: 7,
                    titles: ["Home / X", "Inbox"],
                    urls: ["https://x.com/home", "https://mail.example.com"]
                ),
                listing(
                    window: 8,
                    mode: "incognito",
                    titles: ["Private"],
                    urls: ["https://example.com"]
                ),
            ],
            of: Self.chromeProcess
        )
        #expect(tabs.count == 3)

        #expect(tabs[0].windowIdentifier == 7)
        #expect(tabs[0].tabIndex == 1)
        #expect(tabs[0].host == "x.com")
        #expect(tabs[1].tabIndex == 2)

        // The eligibility that decides whether a request is ever made.
        #expect(tabs[0].allowsFaviconRequest)
        #expect(tabs[1].allowsFaviconRequest)
        #expect(!tabs[2].allowsFaviconRequest, "an incognito window's tabs must never be fetched")
    }

    /// Every tab knows which process it came from, which is what lets two instances of one
    /// browser both be listed and each be switched back to.
    @Test("Tabs carry the process they were listed from")
    func tabsCarryTheirProcess() {
        let mine = BrowserTabService.tabs(
            in: [listing(window: 1_263_791_277, titles: ["Deel"], urls: ["https://app.deel.com/"])],
            of: Self.chromeProcess
        )
        let automation = BrowserTabService.tabs(
            in: [listing(window: 943_944_415, titles: ["Harness"], urls: ["http://127.0.0.1:4173/"])],
            of: BrowserTabService.BrowserProcess(browser: .chrome, processIdentifier: 37_835)
        )

        #expect(mine[0].processIdentifier == 855)
        #expect(automation[0].processIdentifier == 37_835)
        // Identity has to separate them even when the window ids collide, which they can:
        // each instance numbers its windows from its own counter.
        #expect(mine[0].identity != automation[0].identity)
    }

    /// Fails closed. An unrecognised mode is treated as private, because the cost of guessing
    /// wrong is a private address going out over the network.
    @Test(
        "An unknown window mode blocks the icon request",
        arguments: ["", "guest", "unknown", "Normal-ish"]
    )
    func unknownModeBlocksTheRequest(mode: String) {
        let tabs = BrowserTabService.tabs(
            in: [listing(window: 1, mode: mode, titles: ["Something"], urls: ["https://example.com"])],
            of: Self.chromeProcess
        )
        #expect(tabs.count == 1)
        #expect(!tabs[0].allowsFaviconRequest, "mode \"\(mode)\" should not be eligible")
    }

    /// Safari cannot report a mode at all, so it is never asked and every Safari tab is
    /// ineligible — the same fail-closed treatment its windows already get.
    @Test("Safari tabs are never eligible")
    func safariTabsAreNeverEligible() {
        let tabs = BrowserTabService.tabs(
            in: [listing(window: 3, mode: "unknown", titles: ["Page"], urls: ["https://example.com"])],
            of: BrowserTabService.BrowserProcess(browser: .safari, processIdentifier: 501)
        )
        #expect(tabs.count == 1)
        #expect(!tabs[0].allowsFaviconRequest)
    }

    /// A tab with neither a title nor an address is still loading and cannot be matched.
    @Test("Empty tabs are dropped")
    func emptyTabsAreDropped() {
        let tabs = BrowserTabService.tabs(
            in: [listing(window: 2, titles: ["", "Real"], urls: ["", "https://real.example"])],
            of: Self.chromeProcess
        )
        #expect(tabs.count == 1)
        #expect(tabs[0].title == "Real")
    }

    /// A window whose address list came back shorter than its titles still yields tabs. The two
    /// lists are separate events, so one can answer and the other fail.
    @Test("Titles without matching addresses still become tabs")
    func titlesWithoutAddressesStillBecomeTabs() {
        let tabs = BrowserTabService.tabs(
            in: [listing(window: 4, titles: ["First", "Second"], urls: [])],
            of: Self.chromeProcess
        )
        #expect(tabs.map(\.title) == ["First", "Second"])
        #expect(tabs.allSatisfy { $0.url.isEmpty })
    }

    /// Terminal has no URL and no browsing mode. A custom title is enough to keep the tab,
    /// and nothing about it is eligible for a favicon fetch.
    @Test("Terminal tabs come from their custom titles")
    func terminalTabsComeFromCustomTitles() {
        let tabs = BrowserTabService.tabs(
            in: [
                listing(
                    window: 7659,
                    mode: "unknown",
                    titles: ["project — zsh"],
                    urls: ["/dev/ttys004"],
                    frame: CGRect(x: 0, y: 70, width: 877, height: 535)
                ),
            ],
            of: BrowserTabService.BrowserProcess(browser: .terminal, processIdentifier: 604)
        )
        #expect(tabs.count == 1)
        #expect(tabs[0].windowIdentifier == 7659)
        #expect(tabs[0].tabIndex == 1)
        #expect(tabs[0].title == "project — zsh")
        #expect(!tabs[0].allowsFaviconRequest)
        #expect(tabs[0].url.isEmpty)
        #expect(tabs[0].groupKey == nil, "a lone window is not a tab group")
    }

    /// An unnamed session falls back to its tty, so it is still findable.
    @Test("An untitled Terminal session falls back to its tty")
    func untitledTerminalSessionFallsBackToTty() {
        let tabs = BrowserTabService.tabs(
            in: [listing(window: 1, mode: "unknown", titles: [""], urls: ["/dev/ttys020"])],
            of: BrowserTabService.BrowserProcess(browser: .terminal, processIdentifier: 604)
        )
        #expect(tabs.map(\.title) == ["/dev/ttys020"])
    }

    /// The pills in Terminal's title bar are other windows sharing a frame, not `tabs of window`.
    /// Grouping on bounds is what lets Search through Tabs list both.
    @Test("Terminal windows that share a frame are one tab group")
    func terminalWindowsThatShareAFrameAreOneTabGroup() {
        let shared = CGRect(x: 0, y: 70, width: 877, height: 535)
        let tabs = BrowserTabService.tabs(
            in: [
                listing(window: 7659, mode: "unknown", titles: ["grok"], urls: [], frame: shared),
                listing(window: 7656, mode: "unknown", titles: ["zsh"], urls: [], frame: shared),
            ],
            of: BrowserTabService.BrowserProcess(browser: .terminal, processIdentifier: 604)
        )
        #expect(tabs.map(\.title) == ["grok", "zsh"])
        #expect(tabs.map(\.windowIdentifier) == [7659, 7656])
        #expect(Set(tabs.compactMap(\.groupKey)).count == 1)
        #expect(tabs[0].groupKey == "0,70,877,605")
    }

    @Test("Terminal windows on different frames stay separate")
    func terminalWindowsOnDifferentFramesStaySeparate() {
        let tabs = BrowserTabService.tabs(
            in: [
                listing(
                    window: 1,
                    mode: "unknown",
                    titles: ["left"],
                    urls: [],
                    frame: CGRect(x: 0, y: 70, width: 877, height: 535)
                ),
                listing(
                    window: 2,
                    mode: "unknown",
                    titles: ["right"],
                    urls: [],
                    frame: CGRect(x: 900, y: 70, width: 877, height: 535)
                ),
            ],
            of: BrowserTabService.BrowserProcess(browser: .terminal, processIdentifier: 604)
        )
        #expect(tabs.allSatisfy { $0.groupKey == nil })
    }
}
