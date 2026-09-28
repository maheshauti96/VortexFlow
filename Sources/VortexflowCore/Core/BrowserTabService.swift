import AppKit
import Foundation
import ScriptingBridge

/// Lists and selects browser tabs through Apple Events.
///
/// ## Why this is never on the trigger path
///
/// Apple Events are inter-process round trips, and asking for tab titles the obvious way
/// — a property read per tab — measured at 3.4 seconds on a session with two Chrome
/// windows. Fetching whole lists per window instead brings the same work down to roughly
/// 0.3 seconds, because it is a handful of events rather than one per tab. That is what
/// `array(byApplying:)` does here: one event for `title of every tab`, not one per tab.
///
/// 0.3 seconds is still twice the entire budget for putting the overlay on screen
/// (Requirement 14.1), so tabs are never enumerated when the switcher opens. They are
/// fetched once, in the background, only after the user starts typing — the one moment
/// where the user is demonstrably looking for something by name and a short delay before
/// extra results appear reads as normal.
///
/// ## Why every browser is addressed by process id
///
/// A bundle identifier does not name a process. Two copies of one browser run side by side
/// whenever a tool launches its own instance against a separate profile — Puppeteer,
/// `chrome-devtools-mcp`, Selenium, or a second profile started by hand — and both report
/// `com.google.Chrome`.
///
/// `tell application "Google Chrome"` resolves through Launch Services, which picks exactly
/// one of them. Measured on a machine running both: the name resolved to the automation copy
/// and reported its 4 `localhost` tabs, while the user's own Chrome — two windows, 24 tabs —
/// was invisible to search. Nothing failed and nothing was logged, because the script
/// succeeded; it simply answered about the other Chrome. That is the bug this addressing
/// fixes, and it is why `scriptingName` is now only a display fallback.
///
/// Scripting Bridge is used rather than AppleScript text because it is the only one of the
/// three that honours a process. AppleScript re-resolves by name even when handed a `kpid`
/// or `typeProcessSerialNumber` target, and `OSALanguageInstance.defaultTarget` rejects a pid
/// descriptor outright with `-1716`.
///
/// ## Permission
///
/// Controlling another application needs Automation authorisation, granted per target
/// application on first use. There is no way to ask for it up front, and no way to know
/// it was refused except by trying: a refusal surfaces as error −1743. That is treated as
/// "no tabs", never as a failure worth interrupting the user over.
actor BrowserTabService {

    /// macOS reports a refused Automation prompt as this error.
    private static let notAuthorizedError = -1743

    /// Browsers whose Automation prompt was refused, keyed by process.
    ///
    /// Per process, not per browser: consent is granted against the target's code identity, so
    /// two instances of one browser share it in practice — but a pid that refused is the only
    /// thing actually observed, and remembering the bundle would silence a second instance that
    /// was never asked.
    private var deniedProcesses: Set<pid_t> = []
    /// Processes that have answered at least one Apple Event this session. A window refresh while
    /// the overlay is visible is restricted to this set, so it can never summon a first-time
    /// Automation consent dialog over the switcher.
    private var authorizedProcesses: Set<pid_t> = []

    /// Every tab open in every supported browser that is currently running.
    ///
    /// Every *instance* of it. Two Chromes are two entries in `runningBrowserProcesses` and
    /// both are listed, because the user has no reason to care which process a tab lives in.
    func tabs() async -> [BrowserTab] {
        let running = await MainActor.run { Self.runningBrowserProcesses() }
        guard !running.isEmpty else { return [] }

        var all: [BrowserTab] = []
        for process in running where !deniedProcesses.contains(process.processIdentifier) {
            switch Self.enumerateTabs(process) {
            case .success(let tabs):
                authorizedProcesses.insert(process.processIdentifier)
                all.append(contentsOf: tabs)
            case .denied:
                // Remember, so a user who declined the prompt is not asked again on every
                // keystroke for the rest of the session.
                deniedProcesses.insert(process.processIdentifier)
                Log.registry.info("""
                    Automation permission for \(process.browser.scriptingName, privacy: .public) \
                    (pid \(process.processIdentifier, privacy: .public)) was refused; \
                    its tabs will not be searched
                    """)
            case .failed(let message):
                Log.registry.debug("""
                    could not list \(process.browser.scriptingName, privacy: .public) \
                    (pid \(process.processIdentifier, privacy: .public)) tabs: \
                    \(message, privacy: .public)
                    """)
            }
        }
        return all
    }

    /// Every window of every running Chromium browser, including its active-tab URL when the
    /// browser exposes one.
    ///
    /// - Parameter allowPermissionPrompt: When `false`, only processes that have already answered
    ///   an Apple Event this session are queried. This is the only mode used while the overlay is
    ///   visible, preventing a first-time Automation dialog from taking focus. The `true` mode is
    ///   used after dismissal, where macOS may safely ask for access.
    ///
    /// Much cheaper than `tabs()`: a few events per browser rather than per-tab lists to marshal —
    /// around 60 ms for a session with three Chrome windows against roughly 300 ms to enumerate
    /// their tabs. It still never runs on the 150 ms trigger path.
    ///
    /// Safari is excluded. Its scripting dictionary has no equivalent of `mode`, so a Safari
    /// private window is indistinguishable from an ordinary one from out here. Terminal is
    /// included even without a mode: its windows have to be paired so "Search through Tabs"
    /// can name the window whose tabs to list.
    func windows(allowPermissionPrompt: Bool = true) async -> [ScriptedBrowserWindow] {
        let running = await MainActor.run { Self.runningBrowserProcesses() }
        let scriptable = running.filter {
            $0.browser.needsWindowInspection
                && !deniedProcesses.contains($0.processIdentifier)
                && (allowPermissionPrompt || authorizedProcesses.contains($0.processIdentifier))
        }
        guard !scriptable.isEmpty else { return [] }

        var all: [ScriptedBrowserWindow] = []
        for process in scriptable {
            switch Self.enumerateWindows(process) {
            case .success(let windows):
                authorizedProcesses.insert(process.processIdentifier)
                all.append(contentsOf: windows)
            case .denied:
                deniedProcesses.insert(process.processIdentifier)
                Log.registry.info("""
                    Automation permission for \(process.browser.scriptingName, privacy: .public) \
                    (pid \(process.processIdentifier, privacy: .public)) was refused; \
                    its windows will not be inspected
                    """)
            case .failed(let message):
                Log.registry.debug("""
                    could not list \(process.browser.scriptingName, privacy: .public) \
                    (pid \(process.processIdentifier, privacy: .public)) windows: \
                    \(message, privacy: .public)
                    """)
            }
        }
        return all
    }

    /// Bring a tab to the front: activate the browser, select the tab within its window, and raise
    /// that window.
    ///
    /// ## Why activation comes first
    ///
    /// It used to come last, which reads more naturally — set everything up, then bring the browser
    /// forward — and it does not work when the tab's window is on another desktop. Raising a window
    /// while its application is in the background does not move it: measured against a Chrome with
    /// one window on this Space and one on another, raising the off-Space window and then activating
    /// left the *on-Space* window in front, three times out of three. Activating first and raising
    /// second put the right window in front, and pulled its desktop with it, three times out of
    /// three.
    ///
    /// That is exactly the reported symptom — "it opened another Chrome window, and the second
    /// attempt opened the right tab". The first attempt's activation made the browser frontmost
    /// without honouring the raise, so the second attempt found it already frontmost and the raise
    /// then worked. Two presses did the job of one, and the first press looked like it had picked
    /// the wrong window.
    ///
    /// Only the order matters, and it is worth saying what did *not* need to change. A first attempt
    /// at this waited for the browser to report itself frontmost before raising, on the assumption
    /// that activation returns too early. It does return early, but the wait was useless: AppleScript's
    /// `frontmost` is already true the moment activation is *requested*, so the loop ran zero times
    /// and the script it guarded still failed. A fixed delay in its place was not needed either —
    /// activating first works with no pause at all, across every delay tried from 0 to 0.5 s.
    func activate(_ tab: BrowserTab) -> Bool {
        guard tab.processIdentifier > 0 else { return false }
        let session = Session(processIdentifier: tab.processIdentifier)
        guard let application = session.application else { return false }

        // The window has to be found before anything is touched, so a stale id fails without
        // having already pulled the browser forward over whatever the user was looking at.
        guard let window = session.window(id: tab.windowIdentifier, of: application, browser: tab.browser),
              let tabs = session.tabs(of: window),
              tabs.count >= tab.tabIndex
        else { return false }

        for step in Self.activationSteps(for: tab) {
            switch step {
            case .activateApplication:
                application.activate?()
            case .selectTabByIndex(let index):
                window.setValue(index, forKey: "activeTabIndex")
            case .selectTabByObject(let index):
                guard let target = tabs.object(at: index - 1) as? SBObject else { return false }
                window.setValue(target, forKey: "currentTab")
            case .markTabSelected(let index):
                guard let target = tabs.object(at: index - 1) as? SBObject else { return false }
                target.setValue(true, forKey: "selected")
            case .raiseWindow:
                window.setValue(1, forKey: "index")
            }
        }
        return !session.wasDenied && session.failures.isEmpty
    }

    // MARK: - Activation order

    /// One operation in the activation sequence. Ordering is the whole of the bug fixed above,
    /// and a sequence of cases is something a test can assert on without a running browser.
    enum ActivationStep: Equatable {
        case activateApplication
        /// Chromium: `active tab index` of the window.
        case selectTabByIndex(Int)
        /// Safari: `current tab` is set to a tab object, not an index.
        case selectTabByObject(Int)
        /// Terminal: `selected` is set on the tab itself.
        case markTabSelected(Int)
        case raiseWindow
    }

    /// The order operations must happen in. Activation first, selection before the raise.
    static func activationSteps(for tab: BrowserTab) -> [ActivationStep] {
        let selection: ActivationStep
        if tab.browser.usesCurrentTab {
            selection = .selectTabByObject(tab.tabIndex)
        } else if tab.browser.usesSelectedTab {
            selection = .markTabSelected(tab.tabIndex)
        } else {
            selection = .selectTabByIndex(tab.tabIndex)
        }
        return [.activateApplication, selection, .raiseWindow]
    }

    // MARK: - Enumeration

    /// One running instance of a supported browser.
    struct BrowserProcess: Equatable, Sendable {
        let browser: BrowserTab.Browser
        let processIdentifier: pid_t
    }

    private enum TabsOutcome {
        case success([BrowserTab])
        case denied
        case failed(String)
    }

    private enum WindowsOutcome {
        case success([ScriptedBrowserWindow])
        case denied
        case failed(String)
    }

    /// Every running process of every supported browser.
    ///
    /// Processes, not bundle identifiers. `runningApplications` lists each instance separately
    /// even when two share an identifier, which is the only place that distinction is available
    /// — Launch Services collapses it as soon as anything is addressed by name.
    @MainActor
    static func runningBrowserProcesses() -> [BrowserProcess] {
        let browsersByBundle = Dictionary(
            BrowserTab.Browser.allCases.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  let bundle = application.bundleIdentifier,
                  let browser = browsersByBundle[bundle],
                  application.processIdentifier > 0
            else { return nil }
            return BrowserProcess(
                browser: browser,
                processIdentifier: application.processIdentifier
            )
        }
    }

    private static func enumerateTabs(_ process: BrowserProcess) -> TabsOutcome {
        let session = Session(processIdentifier: process.processIdentifier)
        guard let application = session.application else {
            return .failed("process is not scriptable")
        }
        guard let windows = session.windows(of: application) else {
            return session.wasDenied
                ? .denied
                : .failed(session.failureReason("no window list"))
        }

        var listings: [Session.WindowListing] = []
        for case let window as SBObject in windows {
            guard let listing = session.listing(of: window, browser: process.browser) else {
                continue
            }
            listings.append(listing)
        }
        // Denial is checked after the walk, not instead of it: consent is per target application,
        // so a refusal shows up on the first event and every later one, and the partial list a
        // refused walk produces is not something to hand back as success.
        if session.wasDenied { return .denied }
        if listings.isEmpty, !session.failures.isEmpty {
            return .failed(session.failureReason("no windows listed"))
        }
        return .success(Self.tabs(in: listings, of: process))
    }

    private static func enumerateWindows(_ process: BrowserProcess) -> WindowsOutcome {
        let session = Session(processIdentifier: process.processIdentifier)
        guard let application = session.application else {
            return .failed("process is not scriptable")
        }
        guard let windows = session.windows(of: application) else {
            return session.wasDenied
                ? .denied
                : .failed(session.failureReason("no window list"))
        }

        var records: [ScriptedBrowserWindow] = []
        for case let window as SBObject in windows {
            guard let record = session.windowRecord(of: window, process: process) else { continue }
            records.append(record)
        }
        if session.wasDenied { return .denied }
        if records.isEmpty, !session.failures.isEmpty {
            return .failed(session.failureReason("no windows listed"))
        }
        return .success(records)
    }

    // MARK: - Model building

    /// Turn per-window listings into tabs.
    ///
    /// Separated from the Apple Event traffic so the rules — which tabs are dropped, how a
    /// missing address is handled, how Terminal's window-tabbing is grouped — are testable
    /// without a running browser.
    static func tabs(in listings: [Session.WindowListing], of process: BrowserProcess) -> [BrowserTab] {
        if process.browser == .terminal {
            return terminalTabs(in: listings, of: process)
        }

        return listings.flatMap { listing in
            listing.titles.enumerated().compactMap { offset, title in
                let url = offset < listing.urls.count ? listing.urls[offset] : ""
                // A tab with neither a title nor an address is still loading and cannot be
                // matched against anything useful.
                guard !title.isEmpty || !url.isEmpty else { return nil }
                return BrowserTab(
                    browser: process.browser,
                    processIdentifier: process.processIdentifier,
                    windowIdentifier: listing.identifier,
                    // Scripting indexes from one, and the index is what selects it.
                    tabIndex: offset + 1,
                    title: title,
                    url: url,
                    // Only the browser's exact `normal` answer permits a network request for
                    // this tab's icon. Anything else — incognito, an unrecognised mode, or a
                    // browser that cannot report one at all — is treated as private.
                    allowsFaviconRequest: listing.mode == "normal"
                )
            }
        }
    }

    /// Terminal tabs, grouped by the rectangle their windows share.
    ///
    /// Terminal's `tabs of window` are sessions inside one window. The pills in the title bar are
    /// often *other windows* merged by macOS window-tabbing, each with one session, sharing a
    /// rectangle. Windows that share one get the same `groupKey` so a scope on the front window
    /// includes its neighbours.
    private static func terminalTabs(
        in listings: [Session.WindowListing],
        of process: BrowserProcess
    ) -> [BrowserTab] {
        let groupKeys = listings.map { listing -> String in
            let frame = listing.frame ?? .zero
            return [frame.minX, frame.minY, frame.maxX, frame.maxY]
                .map { String(Int($0.rounded())) }
                .joined(separator: ",")
        }
        let sharedCounts = groupKeys.reduce(into: [String: Int]()) { counts, key in
            counts[key, default: 0] += 1
        }

        return zip(listings, groupKeys).flatMap { listing, groupKey -> [BrowserTab] in
            // A unique frame is just a window, not a tab bar.
            let shared = (sharedCounts[groupKey] ?? 0) > 1 ? groupKey : nil
            return listing.titles.enumerated().compactMap { offset, title in
                // `custom title` is what the user set; `tty` is always present and is the
                // fallback so an untitled session is still findable.
                let resolved = title.isEmpty
                    ? (offset < listing.urls.count ? listing.urls[offset] : "")
                    : title
                guard !resolved.isEmpty else { return nil }
                return BrowserTab(
                    browser: .terminal,
                    processIdentifier: process.processIdentifier,
                    windowIdentifier: listing.identifier,
                    tabIndex: offset + 1,
                    title: resolved,
                    url: "",
                    allowsFaviconRequest: false,
                    groupKey: shared
                )
            }
        }
    }

    /// Turn one window listing into the record the incognito matcher pairs against.
    static func window(
        from listing: Session.WindowListing,
        of process: BrowserProcess
    ) -> ScriptedBrowserWindow {
        ScriptedBrowserWindow(
            browser: process.browser,
            processIdentifier: process.processIdentifier,
            identifier: listing.identifier,
            // Unknown modes stay visually unbadged, but only an explicit `normal` is
            // eligible for a network favicon request.
            isIncognito: listing.mode == "incognito",
            title: listing.title,
            frame: listing.frame ?? .zero,
            activeTabURL: listing.activeTabURL.flatMap { $0.isEmpty ? nil : $0 },
            allowsFaviconRequest: listing.mode == "normal"
        )
    }

    // MARK: - Scripting Bridge

    /// One conversation with one process.
    ///
    /// Holds the delegate that catches Apple Event failures. Scripting Bridge reports them to a
    /// delegate rather than returning them, and with no delegate installed a refused or failed
    /// event is indistinguishable from an empty answer — which is exactly the class of silent
    /// nothing this whole file is trying to stop producing.
    final class Session {

        /// What one window answered. Flat, so the parsing rules can be exercised directly.
        struct WindowListing: Equatable, Sendable {
            let identifier: Int
            /// Lowercased browsing mode, or `"unknown"` for a browser that has none. Never
            /// optional: the favicon decision reads it and must fail closed.
            let mode: String
            let title: String
            let frame: CGRect?
            let titles: [String]
            /// Tab addresses, positionally aligned with `titles`. For Terminal this carries the
            /// `tty` fallback instead, because Terminal tabs have no address at all.
            let urls: [String]
            let activeTabURL: String?

            init(
                identifier: Int,
                mode: String = "unknown",
                title: String = "",
                frame: CGRect? = nil,
                titles: [String] = [],
                urls: [String] = [],
                activeTabURL: String? = nil
            ) {
                self.identifier = identifier
                self.mode = mode
                self.title = title
                self.frame = frame
                self.titles = titles
                self.urls = urls
                self.activeTabURL = activeTabURL
            }
        }

        private final class Delegate: NSObject, SBApplicationDelegate {
            var failures: [String] = []
            var deniedCount = 0

            func eventDidFail(
                _ event: UnsafePointer<AppleEvent>,
                withError error: Error
            ) -> Any? {
                let error = error as NSError
                if error.code == BrowserTabService.notAuthorizedError {
                    deniedCount += 1
                }
                let description = error.userInfo["ErrorString"] as? String
                failures.append(description ?? "error \(error.code)")
                // Returning nil rather than throwing: a failed event becomes a missing value,
                // which every read here already handles, instead of an exception across a
                // C boundary that cannot be caught in Swift.
                return nil
            }
        }

        private let delegate = Delegate()
        let application: ScriptedApplication?

        var failures: [String] { delegate.failures }
        var wasDenied: Bool { delegate.deniedCount > 0 }

        init(processIdentifier: pid_t) {
            guard let application = SBApplication(processIdentifier: processIdentifier) else {
                self.application = nil
                return
            }
            application.delegate = delegate
            // Bounded rather than indefinite. A browser that has stopped answering must not
            // hold the tab fetch open past the point the controller has given up on it.
            application.timeout = Self.timeoutTicks
            self.application = application as ScriptedApplication
        }

        /// Six seconds, in the 1/60 s ticks Scripting Bridge counts. Far beyond the controller's
        /// own 750 ms budget for using an answer: this exists only so a wedged browser releases
        /// the actor eventually, not as a deadline anything waits on.
        private static let timeoutTicks = 360

        func windows(of application: ScriptedApplication) -> SBElementArray? {
            // Through a declared optional selector, never `value(forKey:)`. KVC on a proxy for a
            // process that has gone away raises `NSUnknownKeyException`, which cannot be caught
            // in Swift and would take the app down; the selector form returns nil instead.
            application.windows?()
        }

        func tabs(of window: SBObject) -> SBElementArray? {
            (window as ScriptedWindow).tabs?()
        }

        /// One window's id, geometry and whole tab lists.
        ///
        /// Whole-collection reads (`array(byApplying:)`) are the entire performance argument for
        /// this path: `title of every tab` is one event, where a loop over tabs is one each.
        func listing(of window: SBObject, browser: BrowserTab.Browser) -> WindowListing? {
            guard let identifier = Self.integer(window.value(forKey: "id")) else { return nil }
            guard let tabs = tabs(of: window) else { return nil }

            let titles = Self.strings(tabs.array(byApplying: Selector((browser.titleProperty))))
            let addresses: [String]
            if browser.hasTabURLs {
                addresses = Self.strings(tabs.array(byApplying: Selector(("URL"))))
            } else {
                // Terminal has no URL on a tab. `tty` is always present and stands in as the
                // fallback title for a session the user never named.
                addresses = Self.strings(tabs.array(byApplying: Selector(("tty"))))
            }

            return WindowListing(
                identifier: identifier,
                mode: Self.mode(of: window, browser: browser),
                title: Self.string(window.value(forKey: "name")),
                frame: Self.rect(window.value(forKey: "bounds")),
                titles: titles,
                urls: addresses
            )
        }

        /// A window record: the same fields the incognito matcher needs, plus the active tab's
        /// address, and without reading whole tab lists.
        func windowRecord(
            of window: SBObject,
            process: BrowserProcess
        ) -> ScriptedBrowserWindow? {
            guard let identifier = Self.integer(window.value(forKey: "id")) else { return nil }

            // Isolated from the rest of the record: one transient or browser-specific failure
            // leaves the window usable with the browser icon fallback instead of failing it.
            var activeTabURL: String?
            if process.browser.hasTabURLs,
               let active = window.value(forKey: "activeTab") as? SBObject {
                activeTabURL = Self.string(active.value(forKey: "URL"))
            }

            return BrowserTabService.window(
                from: WindowListing(
                    identifier: identifier,
                    mode: Self.mode(of: window, browser: process.browser),
                    title: Self.string(window.value(forKey: "name")),
                    frame: Self.rect(window.value(forKey: "bounds")),
                    activeTabURL: activeTabURL
                ),
                of: process
            )
        }

        /// The window carrying `id`, within this process.
        func window(
            id: Int,
            of application: ScriptedApplication,
            browser: BrowserTab.Browser
        ) -> SBObject? {
            guard let windows = windows(of: application) else { return nil }
            // Chrome types a window id as text and Safari and Terminal as an integer, and
            // `object(withID:)` builds a specifier from whatever it is handed — so the wrong
            // one names nothing. Scanning the ids that came back avoids guessing per browser.
            for case let window as SBObject in windows {
                guard Self.integer(window.value(forKey: "id")) == id else { continue }
                return window
            }
            return nil
        }

        /// Why nothing came back, for a caller that has to distinguish refusal from failure.
        func failureReason(_ fallback: String) -> String { failures.first ?? fallback }

        /// The browser's reported mode, lowercased, or `"unknown"`.
        ///
        /// Asked only of browsers that declare `mode`. Reading a property a dictionary does not
        /// have is an event failure, and Safari and Terminal simply have no browsing mode — so
        /// they report `"unknown"` and their tabs stay ineligible for a network favicon request.
        private static func mode(of window: SBObject, browser: BrowserTab.Browser) -> String {
            guard browser.reportsWindowMode else { return "unknown" }
            let mode = string(window.value(forKey: "mode"))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return mode.isEmpty ? "unknown" : mode
        }

        // MARK: Coercion
        //
        // Scripting Bridge hands back `Any?` from an untyped bridge: a window id arrives as
        // `NSString` from Chrome and `NSNumber` from Safari, and a failed event arrives as nil.
        // Every read goes through one of these so a type surprise is a missing value rather
        // than a crash.

        private static func integer(_ value: Any?) -> Int? {
            switch value {
            case let number as NSNumber: return number.intValue
            case let text as String: return Int(text)
            default: return nil
            }
        }

        private static func string(_ value: Any?) -> String {
            switch value {
            case let text as String: return text
            case let number as NSNumber: return number.stringValue
            default: return ""
            }
        }

        private static func strings(_ value: [Any]?) -> [String] {
            (value ?? []).map { string($0) }
        }

        /// A window rectangle, in the same top-left-origin space `CGWindowList` uses.
        private static func rect(_ value: Any?) -> CGRect? {
            guard let value = value as? NSValue else { return nil }
            return value.rectValue
        }
    }
}

/// The scripting terms this file sends, declared rather than imported.
///
/// Generating headers from each browser's dictionary would need `sdef`/`sdp` at build time,
/// which an Xcode-less Command Line Tools install does not have — and the terms actually used
/// here are a handful shared across Chromium, Safari and Terminal. Declared `optional`, so a
/// process that has gone away returns nil instead of raising an uncatchable Objective-C
/// exception through KVC.
@objc protocol ScriptedApplication {
    @objc optional func windows() -> SBElementArray
    @objc optional func activate()
}

@objc protocol ScriptedWindow {
    @objc optional func tabs() -> SBElementArray
}

extension SBApplication: ScriptedApplication {}
extension SBObject: ScriptedWindow {}
