import AppKit
import ApplicationServices
import Foundation

/// Reads which individual browser tabs are playing audio or recording, from the tab strip's
/// accessibility tree.
///
/// This is the only route to per-tab media state that exists outside a browser extension. Neither
/// Chrome's nor Safari's scripting dictionary has an audio property — Chrome's `tab` class offers
/// exactly `id`, `title`, `URL` and `loading` — and CoreAudio works in processes, which a browser
/// shares across every tab it has open.
///
/// ## Cost
///
/// Measured against a live Chrome with 18 tabs, over 10 samples of the whole thing including finding
/// the strip: min 3.5 ms, median 7.0 ms, max 11.7 ms. Called off the presentation path anyway, since
/// AX calls are IPC round trips into an application that may be busy, and `AXBridge`'s timeout bounds
/// a stall rather than preventing one.
///
/// ## Requires Accessibility
///
/// Without that grant this returns nothing, and tabs simply go unmarked while windows keep their
/// badge from CoreAudio, which needs no permission at all.
enum BrowserTabAlertService {

    /// Depth limit for finding a tab strip.
    ///
    /// The strip sat 9 levels below the application on the Chrome measured here, nested in
    /// browser-chrome groups. The allowance is a little larger because that nesting is Chrome's
    /// business and changes between versions.
    private static let maximumStripDepth = 14

    /// Ceiling on tabs read per strip, so a window with a pathological number of them cannot turn
    /// this into an unbounded walk.
    private static let maximumTabsPerStrip = 200

    /// Every alerting tab across the given browser processes.
    ///
    /// - Parameter processes: the browser pids that own tab results on screen. Nothing else is
    ///   walked: this is an expensive tree to descend and there is no reason to visit a browser
    ///   whose tabs are not being shown.
    static func survey(browserProcesses processes: Set<pid_t>) -> TabMediaAlert.Survey {
        guard !processes.isEmpty, AXIsProcessTrusted() else { return .empty }

        var survey = TabMediaAlert.Survey()
        for pid in processes {
            let application = AXUIElementCreateApplication(pid)
            AXBridge.applyMessagingTimeout(application)

            for (windowID, strip) in tabStrips(under: application) {
                for tab in tabButtons(of: strip) {
                    guard
                        let description = AXBridge.string(tab, kAXDescriptionAttribute as String),
                        let alert = TabMediaAlert.parse(accessibilityDescription: description)
                    else { continue }
                    survey.readings.append(
                        TabMediaAlert.Reading(
                            processID: pid,
                            windowID: windowID,
                            accessibilityDescription: description,
                            alert: alert
                        )
                    )
                }
            }
        }
        return survey
    }

    /// Find the tab strips, breadth-first, descending only through container roles.
    ///
    /// Breadth-first and stopping at the first level that yields a strip, because a browser window's
    /// tree is mostly page content and a depth-first walk would wander into it. Refusing to descend
    /// into anything but a window, group or toolbar is the other half of that: the rendered document
    /// is an `AXWebArea`, which is never entered, so this cannot end up reading the page.
    /// - Returns: each strip with the window it belongs to, so an alert can be attributed to one
    ///   window rather than to the whole browser. Descent is per window for exactly that reason: a
    ///   single flat sweep would find every strip and lose which window each came from.
    private static func tabStrips(under application: AXUIElement) -> [(CGWindowID?, AXUIElement)] {
        let windows = AXBridge.elements(application, kAXWindowsAttribute as String) ?? []
        var found: [(CGWindowID?, AXUIElement)] = []

        for window in windows {
            let windowID = AXBridge.windowID(for: window)
            if let strip = tabStrip(in: window) {
                found.append((windowID, strip))
            }
        }
        return found
    }

    private static func tabStrip(in window: AXUIElement) -> AXUIElement? {
        var candidates: [AXUIElement] = []
        var frontier = [window]
        var depth = 0
        while !frontier.isEmpty, depth < maximumStripDepth {
            var next: [AXUIElement] = []
            for element in frontier {
                let role = AXBridge.string(element, kAXRoleAttribute as String) ?? ""
                if role == "AXTabGroup" {
                    // Chrome puts empty AXTabGroups in the tab-search chrome, then
                    // the real strip further down. Returning the first one listed
                    // every window as having no tabs.
                    candidates.append(element)
                    continue
                }
                guard role == "AXWindow" || role == "AXGroup" || role == "AXToolbar"
                else { continue }
                next.append(
                    contentsOf: AXBridge.elements(element, kAXChildrenAttribute as String) ?? []
                )
            }
            frontier = next
            depth += 1
        }
        guard let index = preferredTabStripIndex(tabCounts: candidates.map { tabButtons(of: $0).count })
        else { return nil }
        return candidates[index]
    }

    /// The strip that actually holds tabs. Empty neighbours (tab-search chrome,
    /// collapsed Chrome tab groups) stay in the list but must not win.
    static func preferredTabStripIndex(tabCounts: [Int]) -> Int? {
        guard !tabCounts.isEmpty else { return nil }
        return tabCounts.indices.max(by: { tabCounts[$0] < tabCounts[$1] })
    }

    /// Every tab in this browser process, keyed by the window server's id.
    ///
    /// Chrome's AppleScript `windows` collection is empty on current macOS even while
    /// two windows are on screen — System Events and Accessibility still see them.
    /// Search through Tabs uses this listing so it is not stuck on "Looking for tabs…"
    /// waiting for a dictionary that names nothing.
    static func tabs(inProcess pid: pid_t, browser: BrowserTab.Browser) -> [BrowserTab] {
        guard pid > 0, AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXBridge.applyMessagingTimeout(application)
        var listed: [BrowserTab] = []
        for (windowID, strip) in tabStrips(under: application) {
            guard let windowID else { continue }
            listed.append(
                contentsOf: tabs(
                    inStrip: strip,
                    windowID: windowID,
                    browser: browser,
                    processIdentifier: pid
                )
            )
        }
        return listed
    }

    /// Tabs of one window, from a live Accessibility element. Works for windows
    /// Accessibility remembered on another Space, which the application's current
    /// window list does not include.
    static func tabs(
        inWindow element: AXUIElement,
        windowID: CGWindowID,
        browser: BrowserTab.Browser,
        processIdentifier: pid_t = 0
    ) -> [BrowserTab] {
        AXBridge.applyMessagingTimeout(element)
        guard let strip = tabStrip(in: element) else { return [] }
        return tabs(
            inStrip: strip,
            windowID: windowID,
            browser: browser,
            processIdentifier: processIdentifier
        )
    }

    private static func tabs(
        inStrip strip: AXUIElement,
        windowID: CGWindowID,
        browser: BrowserTab.Browser,
        processIdentifier: pid_t
    ) -> [BrowserTab] {
        tabButtons(of: strip).enumerated().compactMap { offset, button in
            let title = resolvedTabTitle(
                axTitle: AXBridge.string(button, kAXTitleAttribute as String),
                accessibilityDescription: AXBridge.string(button, kAXDescriptionAttribute as String)
            )
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return BrowserTab(
                browser: browser,
                // The owning process, so a later scripting record is matched against the
                // instance this strip belongs to rather than whichever one shares its
                // bundle identifier.
                processIdentifier: processIdentifier,
                windowIdentifier: Int(windowID),
                tabIndex: offset + 1,
                title: trimmed,
                url: "",
                usesNativeWindowIdentifier: true
            )
        }
    }

    /// Select a tab that was listed from the accessibility strip, then raise its window.
    ///
    /// The application is activated *before* the raise. Raising an off-Space window
    /// while its app is in the background does not switch desktops — the same bug the
    /// AppleScript path already documents. The parent `windowElement` has to be the
    /// remembered window: Accessibility's current list does not include other Spaces.
    @discardableResult
    static func selectTab(
        processID: pid_t,
        windowID: CGWindowID,
        tabIndex: Int,
        windowElement: AXUIElement? = nil
    ) -> Bool {
        guard processID > 0, AXIsProcessTrusted() else { return false }
        let window = windowElement ?? {
            let application = AXUIElementCreateApplication(processID)
            AXBridge.applyMessagingTimeout(application)
            return (AXBridge.elements(application, kAXWindowsAttribute as String) ?? [])
                .first { AXBridge.windowID(for: $0) == windowID }
        }()
        guard let window, let strip = tabStrip(in: window) else { return false }
        let buttons = tabButtons(of: strip)
        guard buttons.indices.contains(tabIndex - 1) else { return false }
        NSRunningApplication(processIdentifier: processID)?.activate()
        let pressed = AXBridge.perform(buttons[tabIndex - 1], kAXPressAction as String)
        AXBridge.perform(window, kAXRaiseAction as String)
        AXBridge.setBool(window, kAXMainAttribute as String, true)
        AXBridge.setBool(window, kAXFocusedAttribute as String, true)
        return pressed
    }

    /// Chrome leaves `AXTitle` empty and puts the page name in the description.
    /// `??` does not treat `""` as missing, so that empty title used to drop every tab.
    static func resolvedTabTitle(axTitle: String?, accessibilityDescription: String?) -> String {
        let titled = (axTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !titled.isEmpty { return titled }
        return TabMediaAlert.title(fromAccessibilityDescription: accessibilityDescription ?? "")
    }

    /// The tabs of a strip, which are its radio buttons.
    ///
    /// Filtered on the subrole rather than the role: a strip also holds the new-tab button and,
    /// depending on the version, tab-search and tab-group affordances, and only a real tab carries
    /// `AXTabButton`.
    private static func tabButtons(of strip: AXUIElement) -> [AXUIElement] {
        let children = AXBridge.elements(strip, kAXChildrenAttribute as String) ?? []
        return children.prefix(maximumTabsPerStrip).filter { child in
            AXBridge.string(child, kAXSubroleAttribute as String) == "AXTabButton"
        }
    }
}
