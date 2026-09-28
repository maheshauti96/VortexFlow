import CoreGraphics
import Foundation

/// A browser window as its own scripting interface describes it.
///
/// Exists for one thing the window server cannot answer: whether a window is a private one.
/// Neither Accessibility nor `CGWindowList` exposes anything about private browsing — an
/// incognito Chrome window is an ordinary window with an ordinary title — so the only source is
/// the browser itself, which reports `mode` per window over Apple Events.
struct ScriptedBrowserWindow: Equatable, Sendable {

    let browser: BrowserTab.Browser
    /// The process that answered. `0` when unknown. Two instances of one browser each have
    /// their own windows, so pairing a native window with a scripted one has to stay within
    /// the process that owns both.
    let processIdentifier: pid_t
    /// The browser's own window id, not a `CGWindowID`. Unique only within `processIdentifier`.
    let identifier: Int
    let isIncognito: Bool
    /// Network loading fails closed. Only the browser's exact, documented `normal` mode sets
    /// this; unknown or future modes remain unbadged but never disclose their active origin.
    let allowsFaviconRequest: Bool
    /// The window's title, which is also what Accessibility reports for it. The primary key
    /// for matching this back to a `WindowEntry`.
    let title: String
    /// Screen rectangle, in the same top-left-origin space `CGWindowList` uses.
    let frame: CGRect
    /// URL of the active tab when the browser exposed one. Kept as text here so malformed,
    /// internal and non-network URLs can be rejected by the favicon loader without making an
    /// otherwise useful window record fail to parse.
    let activeTabURL: String?

    init(
        browser: BrowserTab.Browser,
        processIdentifier: pid_t = 0,
        identifier: Int,
        isIncognito: Bool,
        title: String,
        frame: CGRect,
        activeTabURL: String? = nil,
        allowsFaviconRequest: Bool? = nil
    ) {
        self.browser = browser
        self.processIdentifier = processIdentifier
        self.identifier = identifier
        self.isIncognito = isIncognito
        // Existing fixtures describe only the two established Chromium modes. Production parsing
        // passes an explicit value so an unrecognised mode cannot inherit the normal default.
        self.allowsFaviconRequest = allowsFaviconRequest ?? !isIncognito
        self.title = title
        self.frame = frame
        self.activeTabURL = activeTabURL
    }
}

/// Works out which on-screen windows are private browsing windows.
///
/// ## Why this is a matching problem at all
///
/// There is no shared identifier. A browser's scripting interface numbers its windows in its own
/// namespace, and nothing maps that to a `CGWindowID`; the window server, for its part, knows
/// nothing about browsing modes. So the two descriptions of the same window have to be paired up
/// on what they both report: the title, and the rectangle.
///
/// Neither is reliable alone. Two windows of one browser can share a title — two blank tabs are
/// both "New Tab" — and on a laptop where everything is maximised, windows routinely share a
/// rectangle to the pixel. Matching therefore runs in passes, strongest evidence first, so the
/// unambiguous pairs are settled before the ambiguous ones are guessed at.
enum IncognitoMatcher {

    /// How close two rectangles must be to count as the same window. Rounding between the two
    /// APIs is the only difference worth absorbing.
    static let frameTolerance: CGFloat = 2

    /// Pair each native window with the browser record that describes it.
    ///
    /// This is the shared source of truth for both browsing mode and active-tab URL. Running two
    /// independent matchers could associate those facts with different windows when titles or
    /// frames are duplicated, so each side is consumed exactly once here.
    static func matchedWindows(
        entries: [WindowEntry],
        scripted: [ScriptedBrowserWindow]
    ) -> [CGWindowID: ScriptedBrowserWindow] {
        guard !scripted.isEmpty else { return [:] }

        // Only real windows of the browsers that answered. Tabs and installed-app search
        // results have no browser window of their own, and an entry from another application
        // cannot be one of these.
        let answered = Set(scripted.map(\.browser.bundleIdentifier))
        var candidates = entries.filter { entry in
            entry.isWindow && entry.bundleIdentifier.map(answered.contains) == true
        }
        guard !candidates.isEmpty else { return [:] }

        var remaining = scripted
        var matched: [CGWindowID: ScriptedBrowserWindow] = [:]

        // Strongest evidence first. A pass settles only mutual one-to-one matches: if two native
        // windows and two scripted windows have the same title and rectangle, array order is not
        // evidence and all four stay unmatched. Repeating a pass lets a pair become unique after
        // a neighbouring unambiguous pair is consumed.
        for requirement in MatchRequirement.allCases {
            while !candidates.isEmpty, !remaining.isEmpty {
                var settled: [(entry: WindowEntry, scripted: ScriptedBrowserWindow)] = []

                for entry in candidates {
                    let possible = remaining.indices.filter {
                        requirement.matches(entry: entry, scripted: remaining[$0])
                    }
                    guard possible.count == 1, let scriptedIndex = possible.first else { continue }

                    let reverseCount = candidates.lazy.filter {
                        requirement.matches(entry: $0, scripted: remaining[scriptedIndex])
                    }.count
                    guard reverseCount == 1 else { continue }

                    settled.append((entry, remaining[scriptedIndex]))
                }

                guard !settled.isEmpty else { break }

                let settledEntryIDs = Set(settled.map { $0.entry.windowID })
                for pair in settled {
                    matched[pair.entry.windowID] = pair.scripted
                }
                candidates.removeAll { settledEntryIDs.contains($0.windowID) }
                remaining.removeAll { window in
                    settled.contains(where: { $0.scripted == window })
                }
            }
        }

        return matched
    }

    /// The `CGWindowID`s of the entries that are private browsing windows.
    ///
    /// Entries that cannot be paired with a scripted window are simply left out — a window whose
    /// mode is unknown is treated as normal, never as private. Getting that the wrong way round
    /// would label ordinary windows as incognito, which is a worse error than missing a badge.
    static func incognitoWindowIDs(
        entries: [WindowEntry],
        scripted: [ScriptedBrowserWindow]
    ) -> Set<CGWindowID> {
        Set(
            matchedWindows(entries: entries, scripted: scripted).compactMap { windowID, window in
                window.isIncognito ? windowID : nil
            }
        )
    }

    /// Shortest run of real characters a browser's title fragment must have before it is allowed
    /// to identify a window by being contained in ours.
    ///
    /// Guards the containment passes against near-empty evidence: a two-character fragment appears
    /// inside almost any title, and matching on it would pair windows essentially at random.
    static let minimumContainedTitleLength = 6

    /// The passes, in the order they run.
    private enum MatchRequirement: CaseIterable {
        /// Same browser, same title, same rectangle. Unambiguous in practice.
        case titleAndFrame
        /// Same browser and title. Distinct titles are the common case, and a title is the more
        /// meaningful of the two signals — it is what the user is reading.
        case title
        /// Same browser and rectangle, and the browser's title found inside ours.
        case containedTitleAndFrame
        /// Same browser, and the browser's title found inside ours. See `containsTitle`.
        case containedTitle
        /// Same browser and rectangle, for a window whose title the two APIs disagree about
        /// (a page that retitled itself between the two reads).
        case frame

        func matches(entry: WindowEntry, scripted: ScriptedBrowserWindow) -> Bool {
            guard entry.bundleIdentifier == scripted.browser.bundleIdentifier else { return false }
            // Same process, when the record says which one. A second instance of the browser
            // has windows of its own that can share a title or a rectangle with the first's.
            guard scripted.processIdentifier == 0 || entry.processID == scripted.processIdentifier
            else { return false }
            switch self {
            case .titleAndFrame:
                return sameTitle(entry, scripted) && sameFrame(entry, scripted)
            case .title:
                return sameTitle(entry, scripted)
            case .containedTitleAndFrame:
                return containsTitle(entry, scripted) && sameFrame(entry, scripted)
            case .containedTitle:
                return containsTitle(entry, scripted)
            case .frame:
                return sameFrame(entry, scripted)
            }
        }

        private func sameTitle(_ entry: WindowEntry, _ scripted: ScriptedBrowserWindow) -> Bool {
            let left = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = scripted.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty title matches any other empty one, which is no evidence at all, so it is
            // not allowed to settle a pair on its own.
            return !left.isEmpty && left == right
        }

        /// Whether the browser's title for a window is present, in order, inside ours.
        ///
        /// Exact equality fails routinely, and on real desktops it fails for both windows of a
        /// browser at once — which is worse than it sounds, because two maximised windows share a
        /// rectangle to the pixel, so the frame pass cannot break the tie either and neither
        /// window gets classified.
        ///
        /// Two things make the strings differ, and they compose:
        ///
        /// - Accessibility reports the window title, which Chrome builds by appending its own name
        ///   and, for a private window, a parenthesised mode: 58 characters of page title arrive as
        ///   86. Stripping a trailing `" - <app name>"` would handle that one case, but the mode
        ///   suffix is localised, so the list of things to strip is unbounded.
        /// - The browser's own scripting name is truncated when the page title is long, and
        ///   Chromium elides the *middle*: a 127-character title came back as 59 with the head and
        ///   tail kept either side of an ellipsis. So the browser's string is not a prefix of ours
        ///   either.
        ///
        /// Splitting the browser's title at its ellipses and requiring every fragment to appear in
        /// order inside ours covers both without knowing anything about a specific browser's
        /// formatting or the user's language. It is deliberately asymmetric — theirs inside ours,
        /// never the reverse — because ours is the one carrying the additions.
        private func containsTitle(_ entry: WindowEntry, _ scripted: ScriptedBrowserWindow) -> Bool {
            let ours = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let theirs = scripted.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ours.isEmpty, !theirs.isEmpty else { return false }

            let fragments = theirs
                .split(whereSeparator: { $0 == "…" || $0 == "\u{2026}" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !fragments.isEmpty,
                  fragments.reduce(0, { $0 + $1.count })
                      >= IncognitoMatcher.minimumContainedTitleLength
            else { return false }

            var searchRange = ours.startIndex..<ours.endIndex
            for fragment in fragments {
                guard let found = ours.range(of: fragment, range: searchRange) else { return false }
                searchRange = found.upperBound..<ours.endIndex
            }
            return true
        }

        private func sameFrame(_ entry: WindowEntry, _ scripted: ScriptedBrowserWindow) -> Bool {
            let tolerance = IncognitoMatcher.frameTolerance
            return abs(entry.frame.minX - scripted.frame.minX) <= tolerance
                && abs(entry.frame.minY - scripted.frame.minY) <= tolerance
                && abs(entry.frame.width - scripted.frame.width) <= tolerance
                && abs(entry.frame.height - scripted.frame.height) <= tolerance
        }
    }
}

/// Which scripting window a card's tabs belong to, from the tab list itself.
///
/// "Search through Tabs" cannot wait on `IncognitoMatcher`: that pairing is asynchronous
/// and often unfinished at the right-click, which left the overlay on "Looking for tabs…"
/// forever. The tab list already groups tabs by the browser's window id, so a unique
/// title (or a single window of that browser) is enough to name the scope.
enum TabWindowMatcher {

    static func scriptingIdentifier(
        for entry: WindowEntry,
        siteHost: String? = nil,
        in tabs: [BrowserTab]
    ) -> Int? {
        guard let bundle = entry.bundleIdentifier else { return nil }
        let relevant = tabs.filter {
            $0.browser.bundleIdentifier == bundle && $0.belongsToProcess(of: entry)
        }
        guard !relevant.isEmpty else { return nil }

        let grouped = Dictionary(grouping: relevant, by: \.windowIdentifier)
        if grouped.count == 1 { return grouped.keys.first }

        let haystack = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var titleHits: [Int] = []
        var hostHits: [Int] = []
        for (identifier, group) in grouped {
            if group.contains(where: { titlesAlign(windowTitle: haystack, tabTitle: $0.title) }) {
                titleHits.append(identifier)
            }
            if let siteHost, !siteHost.isEmpty,
               group.contains(where: { $0.host.caseInsensitiveCompare(siteHost) == .orderedSame }) {
                hostHits.append(identifier)
            }
        }
        if titleHits.count == 1 { return titleHits[0] }
        if hostHits.count == 1 { return hostHits[0] }
        return nil
    }

    static func titlesAlign(windowTitle: String, tabTitle: String) -> Bool {
        let window = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty, !tab.isEmpty else { return false }
        if window == tab { return true }
        if tab.count >= IncognitoMatcher.minimumContainedTitleLength, window.contains(tab) {
            return true
        }
        if window.count >= IncognitoMatcher.minimumContainedTitleLength, tab.contains(window) {
            return true
        }
        return false
    }
}

/// Copy scripting URLs onto Accessibility-listed tabs, without changing their
/// native window ids.
///
/// Search through Tabs reads Chrome's tab strip because it is keyed by the `CGWindowID`
/// already on the card, and it keeps working for a window on another Space that is
/// missing from Accessibility's current window list. The strip has titles and no
/// addresses, so every wedge would otherwise keep the browser icon and the browser name.
/// Scripting still knows every tab's URL across Spaces; matching those onto the listed
/// tabs is what lets favicons and hosts appear.
enum TabAddressMatcher {

    static func enrich(
        _ listed: [BrowserTab],
        with scripted: [BrowserTab],
        window: WindowEntry? = nil
    ) -> [BrowserTab] {
        guard !listed.isEmpty, !scripted.isEmpty else { return listed }
        let browser = listed[0].browser
        let relevant = scripted.filter { tab in
            tab.browser == browser
                && !tab.url.isEmpty
                && (window.map(tab.belongsToProcess(of:)) ?? true)
        }
        guard !relevant.isEmpty else { return listed }

        let pool: [BrowserTab]
        if let window, let identifier = TabWindowMatcher.scriptingIdentifier(for: window, in: relevant) {
            let scoped = relevant.filter { $0.windowIdentifier == identifier }
            pool = scoped.isEmpty ? relevant : scoped
        } else {
            pool = relevant
        }

        var unused = pool
        var assigned: [Int: BrowserTab] = [:]

        func take(_ hit: BrowserTab, for index: Int) {
            assigned[index] = hit
            unused.removeAll {
                $0.browser == hit.browser
                    && $0.windowIdentifier == hit.windowIdentifier
                    && $0.tabIndex == hit.tabIndex
            }
        }

        for (index, tab) in listed.enumerated() where tab.url.isEmpty {
            let exact = unused.filter { $0.title.caseInsensitiveCompare(tab.title) == .orderedSame }
            if exact.count == 1 { take(exact[0], for: index) }
        }

        for (index, tab) in listed.enumerated() where tab.url.isEmpty && assigned[index] == nil {
            let aligned = unused.filter { TabWindowMatcher.titlesAlign(windowTitle: $0.title, tabTitle: tab.title) }
            if aligned.count == 1 { take(aligned[0], for: index) }
        }

        if assigned.count < listed.count, pool.count == listed.count {
            let ordered = pool.sorted { $0.tabIndex < $1.tabIndex }
            for index in listed.indices where listed[index].url.isEmpty && assigned[index] == nil {
                let candidate = ordered[index]
                let stillFree = unused.contains {
                    $0.browser == candidate.browser
                        && $0.windowIdentifier == candidate.windowIdentifier
                        && $0.tabIndex == candidate.tabIndex
                }
                if stillFree { take(candidate, for: index) }
            }
        }

        return listed.enumerated().map { index, tab in
            guard tab.url.isEmpty, let hit = assigned[index] else { return tab }
            return tab.withAddress(
                url: hit.url,
                allowsFaviconRequest: hit.allowsFaviconRequest,
                processIdentifier: hit.processIdentifier,
                scriptedWindowIdentifier: hit.windowIdentifier,
                scriptedTabIndex: hit.tabIndex
            )
        }
    }
}
