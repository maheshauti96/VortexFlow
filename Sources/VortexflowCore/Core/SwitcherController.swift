import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Coordinates a single switch: trigger in, window activated out.
///
/// Everything stateful about a presentation lives here so the services stay
/// independently testable and the requirement traceability stays legible.
///
/// ## The latency path
///
/// Requirement 14.1 gives 150 ms from button press to a visible overlay. The budget
/// is spent like this:
///
/// 1. Event tap callback: reads one integer, hops to main. Microseconds.
/// 2. Window enumeration on a utility queue: the real cost, budgeted at 50 ms by
///    Requirement 1.2 and bounded by `AXBridge.messagingTimeout`.
/// 3. Back on main: order by MRU, load state, position and show the pre-built panel.
///
/// Thumbnails are explicitly *not* on this path. The panel goes up showing app icons
/// and captures land underneath as they complete (Requirement 9.2, 9.3). The panel
/// and its hosting view are built once at launch, because constructing them is tens
/// of milliseconds that the budget cannot absorb.
///
/// ## Why hover is polled
///
/// The panel is non-activating and never key, which makes AppKit's mouse-tracking
/// delivery unreliable for it — particularly while another button is physically held
/// down, as it always is in hold mode. Rather than fight that, the controller samples
/// `NSEvent.mouseLocation` at 60 Hz while the overlay is up and hit-tests with the
/// same `StripLayout` used to draw. The timer exists only during a presentation, so
/// Requirement 14.3's idle CPU budget is untouched.
@MainActor
public final class SwitcherController {

    // MARK: - Collaborators

    private let settings: SettingsStore
    private let permissions: PermissionsManager
    private let registry: WindowRegistry
    private let mruTracker: MRUTracker
    private let thumbnails: ThumbnailService
    private let activation: ActivationService
    private let browserTabs = BrowserTabService()
    private let browserFavicons = BrowserFaviconService()
    private let applicationCatalog = ApplicationCatalog()

    /// Private browsing windows identified during this session.
    ///
    /// Usually stable for a window's lifetime. An explicitly normal browser result may remove an
    /// id because the window server can recycle `CGWindowID`s after a window closes.
    private var knownIncognitoWindowIDs: Set<CGWindowID> = []

    /// Windows whose mode has been settled either way, so a browser is not re-interrogated every
    /// time the overlay closes just because none of its windows turned out to be private.
    private var incognitoResolvedWindowIDs: Set<CGWindowID> = []

    /// A verified browser-window icon, remembered with the window title it was verified against.
    ///
    /// Asking a browser for its windows costs an Apple Event, and a busy browser can take seconds
    /// to answer — far longer than a switch. Without this, a favicon only ever appeared when the
    /// user happened to hold the overlay open long enough for that round trip plus a network
    /// request, so the composed icon looked intermittent.
    ///
    /// The title is the revalidation key, and it is exact rather than heuristic: a Chromium window
    /// takes its title from its active tab, so an identical title means the same tab is still in
    /// front and the previously verified site icon still describes it. A changed title means the
    /// tab moved on, and the entry is ignored until fresh metadata arrives. Nothing here is
    /// persisted, and private windows are never entered.
    private struct CachedBrowserIcon {
        let title: String
        let icon: NSImage
        /// Hue of the site icon, remembered with it so a restored icon also restores the tint the
        /// container had when it was verified.
        let tint: IconTint?
    }

    private var browserIconsByWindowID: [CGWindowID: CachedBrowserIcon] = [:]
    private var browserIconOrder: [CGWindowID] = []
    private static let maximumRememberedBrowserIcons = 64

    /// How many tab results may have their site icon resolved for one visible list.
    ///
    /// A spiral of one window's tabs is often twenty or more. The favicon service
    /// deduplicates by origin, so twenty GitHub tabs still cost one request; this
    /// bound is only admission, not network fan-out.
    private static let maximumVisibleTabIconRequests = 48
    private let triggerMonitor: TriggerMonitor
    private let hotKeyMonitor: HotKeyMonitor

    private let state = OverlayState()
    private var panel: OverlayPanel?

    /// Window enumeration happens here, never on main.
    private let workQueue = DispatchQueue(
        label: "io.vortexflow.enumeration",
        qos: .userInteractive
    )

    /// Installed-app discovery walks the file system and must never queue ahead of a trigger.
    private let applicationCatalogQueue = DispatchQueue(
        label: "io.vortexflow.application-catalog",
        qos: .utility
    )

    // MARK: - Presentation state

    private var presentationMode: PresentationMode = .hold

    /// When the overlay last became visible, for telling a desktop change that happened *under* the
    /// overlay from one that merely finished arriving just after it opened. See `spaceObserver`.
    private var presentedAt: TimeInterval = 0

    /// When a desktop change last caused the overlay to reopen, so a burst of them cannot cycle.
    private var lastSpaceReopen: TimeInterval = 0

    /// A browser window's own scripting identifier, keyed by `CGWindowID`.
    ///
    /// Two identifier spaces meet here: cards are numbered by the window server, and a browser's tabs
    /// are numbered by the browser's private window id. `IncognitoMatcher` already pairs them for the
    /// private-browsing badge; this keeps the pairing rather than discarding it.
    private var scriptedWindowIdentifiers: [CGWindowID: Int] = [:]

    /// A "Search through Tabs" click that arrived before this card was paired. Applied as
    /// soon as the scripting id lands, so the item does not have to wait on pairing to exist.
    private var pendingTabSearchWindowID: CGWindowID?

    /// A tile or Move to Display that is waiting for Full Screen to finish leaving.
    /// Bumped so a second click replaces the first wait rather than stacking.
    private var fullScreenFollowThroughGeneration: UInt64 = 0

    /// True while a card's context menu is tracking.
    ///
    /// Choosing a menu item is a primary click, and a primary click is what dismisses the overlay —
    /// so without this the menu would close the thing it belongs to before its action ran.
    private var isShowingContextMenu = false

    /// The menu currently tracking, so a right-click on another card can close it.
    ///
    /// The event tap runs during menu tracking, which is what makes the second right-click reachable
    /// at all — and without a handle on the first menu it simply stayed open beside the new one.
    private weak var openContextMenu: NSMenu?

    /// How soon after presenting a desktop change is treated as having predated the overlay.
    ///
    /// A Space switch animates for several hundred milliseconds and the notification only arrives
    /// when it lands, while the trigger is a global tap that fires the moment it is pressed. So a
    /// user who switches desktop and reaches for the switcher straight away gets the two in the
    /// opposite order to the one they performed them in, and the observed gap was 3 ms.
    private static let spaceChangeGrace: TimeInterval = 1.0
    private var isPresenting = false
    /// Incremented at the start of every `beginPresentation`. A finish whose attempt
    /// is no longer current is discarded, so a second press can supersede a stuck
    /// Chrome enumeration instead of being swallowed.
    private var presentationAttempt: UInt64 = 0
    /// Set when the trigger comes up before enumeration finished, so a fast flick
    /// still switches instead of being swallowed.
    private var activateAsSoonAsReady = false
    private var hoveredIndex: Int?
    private var scrollAccumulator = SelectionMath.ScrollAccumulator()
    private var captureToken: UInt64 = 0

    private var onButtonCaptured: ((TriggerButton?) -> Void)?
    private var isLoadingBrowserTabs = false
    private var browserTabRequestID: UInt64 = 0
    private static let browserTabSearchTimeoutNanoseconds: UInt64 = 750_000_000

    /// Supersedes browser-window inspections before they can mutate mode caches or publish icons.
    private var browserInspectionGeneration: UInt64 = 0
    /// The only inspection allowed to request first-time Automation access. It waits briefly after
    /// dismissal so a rapid reopen can cancel it before an Apple Event is sent.
    private var browserAuthorizationTask: Task<Void, Never>?
    private var isBrowserAuthorizationInFlight = false
    private static let browserAuthorizationDelayNanoseconds: UInt64 = 250_000_000

    private enum ConfirmationIntent: Equatable {
        case selection
        case returnKey
        /// Shift-Return: skip the results page and open the first web hit.
        case firstWebResult
    }

    private struct PendingSearchConfirmation {
        let presentationID: Int
        let query: String
        let intent: ConfirmationIntent
    }

    /// Confirmation pressed while tabs/apps are resolving. Consumed once the same query settles.
    private var pendingSearchConfirmation: PendingSearchConfirmation?

    /// Held only while the switch animation is on screen, so the panel outlives the call that
    /// started it.
    private var activeTransition: TransitionPanel?

    private var hoverTimer: Timer?

    /// Where the pointer was when something other than the pointer last chose the selection.
    ///
    /// The hover sampler runs on a 60 Hz timer against the pointer's *current* position, and it
    /// sets the selection as well as the highlight. So a stationary pointer re-asserts its own card
    /// on the very next tick — which is what made the arrow keys look inert rather than merely
    /// fighting the mouse: the selection moved and was dragged back inside 16ms, before the screen
    /// had a chance to show it. Nothing was broken about the arrows at all.
    ///
    /// Holding here rather than suppressing hover outright, because hover should resume the moment
    /// the pointer is actually used again — it is only the *stale* position that has no business
    /// overriding a deliberate keystroke.
    private var hoverHoldPoint: CGPoint?

    /// How far the pointer must travel to take the selection back.
    ///
    /// Small, because the only thing being filtered out is a pointer that has not moved at all.
    /// Mouse coordinates arrive with sub-point jitter and a display can report a fractional change
    /// with nothing touching the desk, so zero would not hold.
    private static let hoverReleaseDistance: CGFloat = 3
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    // MARK: - Init

    init(
        settings: SettingsStore,
        permissions: PermissionsManager,
        registry: WindowRegistry = WindowRegistry(),
        mruTracker: MRUTracker = MRUTracker(),
        thumbnails: ThumbnailService = ThumbnailService(),
        triggerMonitor: TriggerMonitor = TriggerMonitor(),
        hotKeyMonitor: HotKeyMonitor = HotKeyMonitor()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.registry = registry
        self.mruTracker = mruTracker
        self.thumbnails = thumbnails
        self.activation = ActivationService(registry: registry, tabs: browserTabs)
        self.triggerMonitor = triggerMonitor
        self.hotKeyMonitor = hotKeyMonitor
        self.activation.onApplicationLaunchFailure = { [weak self] application, error in
            self?.handleApplicationLaunchFailure(application, error: error)
        }
    }

    // MARK: - Lifecycle

    func start() {
        triggerMonitor.delegate = self
        triggerMonitor.triggerButton = settings.triggerButton
        // So the overlay's tap never swallows the shortcut and leaves it unable to close what it
        // opened.
        triggerMonitor.keyboardShortcut = settings.hotKeyShortcut
        triggerMonitor.logsAllHIDInput = settings.logsAllHIDInput
        triggerMonitor.interruptTracking = { [weak self] in
            self?.openContextMenu?.cancelTracking()
        }

        // Requirement 5.14 / 10.9: no tap means hotkey-only, not a dead app.
        let tapInstalled = triggerMonitor.install()
        if !tapInstalled {
            Log.app.info("running with the global hotkey as the only trigger")
        }

        // Requirement 6.1, 6.5.
        registerHotKey(settings.hotKeyShortcut)

        mruTracker.startObserving()
        buildPanel()

        // Pre-warm off the main thread. Loading application icons touches the disk and
        // costs roughly 100 ms across a dozen apps; paying it here means the first
        // trigger of the session is as fast as every later one (Requirement 14.1).
        let registry = self.registry
        workQueue.async {
            registry.warmCaches()
            // Learn the Space the app launched on. Without this, the first trigger is the
            // first time anything is remembered, and a user who switches Space before
            // ever opening the switcher would find that Space's windows missing.
            registry.learnCurrentSpace()
        }

        // Discover installed applications in parallel with the window pre-warm, but on its
        // own utility queue. A file-system walk must never sit ahead of a user-triggered window
        // enumeration on the latency-critical serial queue.
        let applicationCatalog = self.applicationCatalog
        applicationCatalogQueue.async { [weak self] in
            let applications = applicationCatalog.applications().map(WindowEntry.applicationEntry)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Log.registry.info("indexed \(applications.count) installed applications")
                    let changed = self.state.setApplications(applications)
                    if changed, self.state.isVisible {
                        self.afterSearchChanged()
                    }
                    self.resolvePendingSearchConfirmationIfReady()
                }
            }
        }

        // Drop cached state for applications that quit, so a recycled pid can never
        // inherit the wrong name or icon.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                else { return }
                self?.registry.invalidateCache(for: app.processIdentifier)
            }
        }

        // Accessibility only ever reports the windows on the Space that is currently in
        // front, so the only way to know about the others is to look while each one is
        // active. A Space switch is precisely that opportunity, and taking it is what
        // makes windows on other desktops appear in the switcher at all.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // An overlay belongs to the Space it was opened on. The panel joins every Space, so
                // without this it followed the user to the next desktop still listing the windows
                // enumerated on the previous one, and still placed where their cursor had been.
                //
                // Worse than looking stale, it broke the trigger. The overlay counted as visible, so
                // the next press of the shortcut meant "close this" rather than "open here" — which
                // read as the shortcut simply not working on the new desktop.
                let now = Date().timeIntervalSinceReferenceDate
                switch SpaceChangeResponse.resolve(
                    isVisible: self.state.isVisible,
                    presentedAt: self.presentedAt,
                    lastReopenAt: self.lastSpaceReopen,
                    now: now,
                    grace: Self.spaceChangeGrace
                ) {
                case .ignore:
                    break
                case .dismiss:
                    Log.overlay.info("active Space changed; dismissing so the next trigger opens here")
                    self.dismiss(activating: nil)
                case .reopen:
                    self.lastSpaceReopen = now
                    // Captured before dismissing, which resets it to `.hold`.
                    let mode = self.presentationMode
                    Log.overlay.info("""
                        active Space changed \
                        \(Int((now - self.presentedAt) * 1000), privacy: .public)ms after presenting; \
                        reopening for this desktop
                        """)
                    self.dismiss(activating: nil)
                    self.beginPresentation(mode: mode)
                }

                self.learnCurrentSpace()
            }
        }

        // Requirement 8.4.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isVisible else { return }
                Log.overlay.debug("display configuration changed; dismissing")
                self.dismiss(activating: nil)
            }
        }
    }

    /// Requirement 11.4.
    func stop() {
        dismiss(activating: nil)
        triggerMonitor.uninstall()
        hotKeyMonitor.unregister()
        mruTracker.stopObserving()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil

        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil

        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
    }

    /// Enumerate off the main thread purely to populate the registry's memory of which
    /// windows exist, discarding the result.
    ///
    /// Deliberately not on the presentation path: this runs when the user changes Space,
    /// where a few milliseconds of background work costs nothing, so that the next
    /// trigger already knows about the windows over there.
    private func learnCurrentSpace() {
        let registry = self.registry
        workQueue.async {
            registry.learnCurrentSpace()
        }
    }

    /// Requirement 12.3: takes effect without a restart.
    func applySettingsChange() {
        triggerMonitor.triggerButton = settings.triggerButton
        triggerMonitor.keyboardShortcut = settings.hotKeyShortcut

        // Re-register only on an actual change; re-registering needlessly would reset
        // `hasEverFired`, which is the signal used to tell a swallowed shortcut from a
        // broken handler.
        let desired = settings.hotKeyShortcut
        if hotKeyMonitor.registeredShortcut != desired {
            registerHotKey(desired)
        }
    }

    private func registerHotKey(_ shortcut: HotKeyShortcut) {
        let registered = hotKeyMonitor.register(
            shortcut: shortcut,
            onPress: { [weak self] in self?.handleHotKeyPressed() },
            onRelease: { [weak self] held in self?.handleHotKeyReleased(heldFor: held) }
        )
        // Requirement 6.5.
        permissions.setWarning(.hotkeyUnavailable, active: !registered)
    }

    /// Whether the configured shortcut has ever actually fired. Surfaced in Settings,
    /// because `RegisterEventHotKey` reports success even when another app owns the
    /// combination and silently keeps the keystroke.
    var hotKeyHasFired: Bool { hotKeyMonitor.hasEverFired }

    /// Begin capturing the next mouse button press. The callback receives the captured
    /// button, or `nil` if the press was rejected.
    func beginButtonCapture(_ completion: @escaping (TriggerButton?) -> Void) {
        guard triggerMonitor.isInstalled else {
            // No event tap means no button events at all, so capture cannot work.
            completion(nil)
            return
        }
        onButtonCaptured = completion
        triggerMonitor.isCapturingButton = true
    }

    func cancelButtonCapture() {
        triggerMonitor.isCapturingButton = false
        onButtonCaptured = nil
    }

    // MARK: - Panel construction

    private func buildPanel() {
        // `hoveredIndexProvider` lets the SwiftUI tree read hover state without the
        // controller having to publish it through the observable object (hover
        // changes at 60 Hz; selection is what actually needs to be published).
        let view = OverlayHostView(state: state, controller: self)
        panel = OverlayPanel(content: view)
    }

    fileprivate var currentHoveredIndex: Int? { hoveredIndex }

    // MARK: - Presentation

    private func beginPresentation(mode: PresentationMode) {
        // A press arriving while the overlay is up never reaches here: `TriggerResponse` has
        // already turned it into a commit, a dismissal or nothing at all.
        guard !state.isVisible else {
            Log.overlay.info("trigger ignored: the overlay is already visible")
            return
        }

        // Cancel a dismissal-time request that is still in its grace period. The overlay
        // still opens: waiting on Chrome's Automation prompt is how "it does not open
        // on Chrome" happened. A first-time sheet may appear after we are already up.
        invalidateBrowserInspections()

        presentationAttempt &+= 1
        let attempt = presentationAttempt
        if isPresenting {
            Log.overlay.info("superseding an in-flight presentation")
        }
        isPresenting = true
        invalidateBrowserTabLoad()
        pendingSearchConfirmation = nil
        presentationMode = mode
        // The hotkey path is persistent from the outset. The button path starts as a
        // hold and is promoted on release if it turns out to have been a tap.
        state.isPersistent = (mode == .toggle)
        activateAsSoonAsReady = false
        scrollAccumulator.reset()
        hoveredIndex = nil
        // A fresh presentation belongs to the pointer again: the card under the cursor should light
        // up without the user having to jiggle the mouse first.
        hoverHoldPoint = nil

        let stopwatch = Stopwatch("overlay presentation", logger: Log.overlay)

        // Screen geometry must be read on main.
        let cursor = NSEvent.mouseLocation
        let screen = Self.screen(containing: cursor)
        let visibleFrame = screen?.visibleFrame ?? .zero
        let backingScale = screen?.backingScaleFactor ?? 2
        // Read once per presentation, so changing the style in Settings takes effect on
        // the next trigger without a restart (Requirement 12.3). It also chooses the
        // style-specific display budget: radial layouts use more of the display than cards.
        let layoutStyle = settings.overlayLayoutStyle
        let contentWidth = OverlayPlacement.availableContentWidth(visibleFrame: visibleFrame)
        let contentHeight = OverlayPlacement.availableContentHeight(
            visibleFrame: visibleFrame,
            style: layoutStyle
        )
        // Captured here because it reads `NSScreen` for display names, and sampled per
        // presentation so plugging in or unplugging a monitor is picked up on the next
        // trigger rather than needing a restart.
        let displayLayout = DisplayLayout.current()
        let viewMode = layoutStyle.resolvedViewMode(settings.overlayViewMode)
        let pinned = settings.pinnedApplications
        let depth = settings.historyDepth
        // Requirement 15.4: sampled per presentation.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Same treatment for the tint: read per presentation so toggling either the setting or the
        // system's Increase Contrast takes effect on the next trigger rather than needing a restart.
        let tintWindows = settings.tintWindowsByIcon
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        // Hoisted out of the closure: `self` is main-actor isolated, so reaching
        // through it for `registry` on the work queue would be an isolation
        // violation. `WindowRegistry` is internally locked and Sendable.
        let registry = self.registry
        // Captured here, on the main thread, on purpose. See
        // `switchableApplicationsSnapshot()` for why reading the running-application
        // list from the work queue can come back empty right after a switch.
        let applications = registry.switchableApplicationsSnapshot()

        workQueue.async { [weak self] in
            // No retry here on an empty result. `WindowRegistry.enumerate` now
            // cross-checks an empty Accessibility result against CGWindowList and falls
            // back to window-list data, which cannot time out. A retry on top of that
            // only added latency, and invalidating caches to force it made the stall
            // worse by requiring every AX element to be recreated.
            let enumerated = registry.enumerate(applications: applications)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finishPresentation(
                        enumerated: enumerated,
                        cursor: cursor,
                        visibleFrame: visibleFrame,
                        backingScale: backingScale,
                        contentWidth: contentWidth,
                        contentHeight: contentHeight,
                        layoutStyle: layoutStyle,
                        viewMode: viewMode,
                        displayLayout: displayLayout,
                        pinnedApplications: pinned,
                        historyDepth: depth,
                        reduceMotion: reduceMotion,
                        tintWindows: tintWindows,
                        increaseContrast: increaseContrast,
                        stopwatch: stopwatch,
                        attempt: attempt
                    )
                }
            }
        }
    }

    private func finishPresentation(
        enumerated: [WindowEntry],
        cursor: CGPoint,
        visibleFrame: CGRect,
        backingScale: CGFloat,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        layoutStyle: OverlayLayoutStyle,
        viewMode: OverlayViewMode,
        displayLayout: DisplayLayout,
        pinnedApplications: Set<String>,
        historyDepth: Int,
        reduceMotion: Bool,
        tintWindows: Bool,
        increaseContrast: Bool,
        stopwatch: Stopwatch,
        attempt: UInt64
    ) {
        defer {
            if presentationAttempt == attempt {
                isPresenting = false
            }
        }
        guard presentationAttempt == attempt else {
            Log.overlay.debug("stale presentation discarded")
            return
        }
        guard let panel else { return }

        mruTracker.prune(livingWindowIDs: Set(enumerated.map(\.windowID)))
        let ordered = mruTracker.ordered(
            enumerated,
            historyDepth: historyDepth,
            pinnedApplications: pinnedApplications
        )

        state.reduceMotion = reduceMotion
        state.tintsWindowsByIcon = tintWindows
        state.increaseContrast = increaseContrast
        state.availableContentWidth = contentWidth
        state.availableContentHeight = contentHeight
        // Set before `load`, because the layout the state derives — including the
        // initial scroll offset — depends on the style, and `load` resolves each
        // window's display against this arrangement.
        state.layoutStyle = layoutStyle
        state.viewMode = viewMode
        state.displayLayout = displayLayout
        state.canCloseWindows = permissions.accessibilityGranted
        state.hoveredCloseButtonIndex = nil
        state.draggingSlot = nil
        state.hoveredSlot = nil
        refreshSlotIcons()
        state.load(
            entries: ordered.resting,
            // Everything found, so a window the history depth kept out of the resting view is still
            // one keystroke away instead of being denied.
            searchable: ordered.all,
            selectedIndex: SelectionMath.initialSelection(count: ordered.resting.count)
        )

        let size = state.layout.panelSize
        let origin = OverlayPlacement.origin(
            panelSize: size,
            cursor: cursor,
            visibleFrame: visibleFrame,
            anchor: layoutStyle.placementAnchor
        )
        // Force the hosting view to reflect the state set a moment ago before the panel
        // becomes visible. SwiftUI would otherwise apply that update on a later pass,
        // and the first frame on screen would show whatever the strip contained last.
        // The empty-state message always gets a plate, whatever the style, so it also
        // always gets the panel shadow that goes with one.
        let hasPlate = ordered.resting.isEmpty || layoutStyle.drawsBackdrop
        // Read per presentation rather than at launch, so toggling it takes effect on the next
        // trigger instead of needing a restart.
        panel.setIncludedInScreenshots(settings.includeOverlayInScreenshots)
        // Hold the cards back, and give the arrangement a new identity, so the synchronous layout
        // pass below rebuilds it and reads the hidden state rather than relying on change
        // notification to have landed. The first visible frame is then an empty panel for the
        // cards to arrive into.
        state.beginPresentation()
        let revealToken = state.presentationID
        panel.present(at: origin, size: size, afterLayout: true, castsShadow: hasPlate)
        state.isVisible = true
        // Kept in step with `state.isVisible`, because that flag is what decides whether the next
        // trigger press opens, commits or is ignored — so a panel that is not actually on screen
        // while the flag says otherwise silently swallows every press.
        Log.overlay.debug("panel ordered front; isVisible now true")
        presentedAt = Date().timeIntervalSinceReferenceDate
        // Where it went is part of the record. "It opened but I could not see it" is
        // indistinguishable from "it did not open" without the display it was drawn on.
        Log.overlay.info("""
            presenting \(ordered.resting.count, privacy: .public) cards \
            (\(ordered.all.count, privacy: .public) searchable) \
            on display \(Self.describe(visibleFrame), privacy: .public) \
            at \(Self.describe(CGRect(origin: origin, size: size)), privacy: .public); \
            pointer \(Int(cursor.x), privacy: .public),\(Int(cursor.y), privacy: .public)
            """)
        stopwatch.log()

        // Requirement 5.6: scroll, keys, and reliable primary-card clicks become
        // interesting only now. Passing the panel frame lets the HID-level tap consume
        // clicks on the overlay while preserving normal click-through outside it.
        triggerMonitor.isSearchActive = state.isSearching
        triggerMonitor.setOverlayTapEnabled(true, clickRegion: panel.frame)
        startHoverTracking()
        installClickMonitors()

        // Let the cards in, on the next run loop pass so the hidden frame the layout above drew
        // has been composited before they start arriving.
        //
        // Stamped with the presentation it belongs to. Without that, triggering twice quickly
        // meant the first presentation's pending reveal fired during the second — which had just
        // set itself hidden — and the second got no entrance at all.
        //
        // Input is already live at this point — hit-testing is arithmetic and does not care
        // whether a card has finished fading in — so the entrance costs no responsiveness.
        DispatchQueue.main.async { [weak self] in
            self?.state.reveal(token: revealToken)
        }

        // Everything found, not only what is drawn. These decorate a window's identity — private
        // browsing, what is making noise, which site a browser window is on — and a window the history
        // depth trimmed can still be reached by typing, so it has to arrive already identified rather
        // than as a bare icon. All three are per application or served from cache, so covering the
        // wider list costs no extra round trip per window.
        applyKnownIncognitoWindows(to: ordered.all)
        refreshAudioActivity(for: ordered.all, presentationID: revealToken)
        // Costs nothing and needs no browser: any window still showing the tab its icon was
        // verified against gets that icon in the first frame instead of waiting for an Apple
        // Event that may take seconds.
        applyRememberedBrowserIcons(to: ordered.all, presentationID: revealToken)
        // This starts only after the panel is on screen. It is restricted to browsers that have
        // already answered an Apple Event this session, so no Automation prompt can steal focus.
        refreshBrowserWindows(for: ordered.all, presentationID: revealToken)

        guard !ordered.resting.isEmpty else { return }
        // The drawn list only. A capture is a screen grab per window, which is the one cost here that
        // scales with the number of windows rather than the number of applications, and a window that
        // is not on screen has nowhere to put one.
        startCaptures(for: ordered.resting, backingScale: backingScale)

        // A release that beat enumeration to the finish line.
        if activateAsSoonAsReady {
            activateAsSoonAsReady = false
            commitSelection()
        }
    }

    /// Badge the private browsing windows already known, without asking anyone.
    ///
    /// Purely a cache read, so it costs nothing and can sit on the presentation path. Restricted
    /// to the windows on screen, so a stale id from a closed window cannot badge a reused one.
    private func applyKnownIncognitoWindows(to entries: [WindowEntry]) {
        let onScreen = Set(entries.map(\.windowID))
        let resolved = knownIncognitoWindowIDs.intersection(onScreen)
        guard resolved != state.incognitoWindowIDs else { return }
        state.incognitoWindowIDs = resolved
    }

    /// Ask CoreAudio what is playing, off the presentation path.
    ///
    /// Off it because of the outlier: the query's median is 6 ms but its measured worst case is
    /// 57 ms, and spending a third of the 150 ms presentation budget (Requirement 14.1) on a badge
    /// is the wrong trade. The panel is already on screen by the time this runs, and the badge
    /// appears a frame or two later — the same deal `refreshBrowserWindows` makes for favicons.
    ///
    /// Stamped with the presentation so a slow answer cannot land on the next one and badge a
    /// window that reused the pid of something that has since quit.
    private func refreshAudioActivity(for entries: [WindowEntry], presentationID: Int) {
        // Restricted to the processes on screen: it is what stops the daemons that permanently hold
        // the input device open from being attributed to anything, and it keeps the ancestor walk
        // short.
        let candidates = Set(entries.filter(\.isWindow).map(\.processID).filter { $0 > 0 })
        guard !candidates.isEmpty else {
            state.audioActivity = .silent
            state.windowMediaAlerts = [:]
            state.narrowedBrowserProcesses = []
            return
        }

        // Browsers get a second, finer question asked of them in the same hop. CoreAudio can only
        // say that Chrome is on the microphone; the tab strip says which of Chrome's windows it is
        // in, which is what a badge drawn on a window needs.
        let browsers = Set(browserWindowCandidates(in: entries).map(\.processID).filter { $0 > 0 })

        workQueue.async { [weak self] in
            let activity = AudioActivityService.current(attributedTo: candidates)

            // Only browsers CoreAudio has already implicated. The tab strip exists here to *narrow*
            // a positive, so a silent browser has nothing to narrow — and this is what keeps the walk
            // off the common path: measured at 16 ms median, it now costs that only when a browser is
            // genuinely making noise, and nothing at all the rest of the time.
            let busy = browsers.filter {
                activity.isPlaying($0) || activity.isRecording($0)
            }
            let survey = busy.isEmpty
                ? TabMediaAlert.Survey.empty
                : BrowserTabAlertService.survey(browserProcesses: busy)
            let windowAlerts = TabMediaAlert.windowAlerts(readings: survey.readings)
            let narrowed = survey.narrowedProcesses

            if !activity.isSilent {
                Log.overlay.info(
                    """
                    audio activity: \(activity.playing.count, privacy: .public) playing, \
                    \(activity.recording.count, privacy: .public) recording, \
                    of \(candidates.count, privacy: .public) windowed processes; \
                    \(busy.count, privacy: .public) busy browsers surveyed, \
                    \(narrowed.count, privacy: .public) narrowed to \
                    \(windowAlerts.count, privacy: .public) windows
                    """
                )
            }
            DispatchQueue.main.async {
                guard let self, self.state.presentationID == presentationID else { return }
                if self.state.audioActivity != activity { self.state.audioActivity = activity }
                if self.state.windowMediaAlerts != windowAlerts {
                    self.state.windowMediaAlerts = windowAlerts
                }
                if self.state.narrowedBrowserProcesses != narrowed {
                    self.state.narrowedBrowserProcesses = narrowed
                }
            }
        }
    }

    /// Restore already-verified browser icons for windows whose active tab has not changed.
    ///
    /// A cache read only, so it is safe on the presentation path: no Apple Event, no network, and
    /// no consent dialog. The title check is what keeps it honest — see `CachedBrowserIcon`.
    private func applyRememberedBrowserIcons(to entries: [WindowEntry], presentationID: Int) {
        guard !browserIconsByWindowID.isEmpty else { return }

        var restored = 0
        for entry in browserWindowCandidates(in: entries) {
            guard let remembered = browserIconsByWindowID[entry.windowID],
                  remembered.title == entry.title,
                  !knownIncognitoWindowIDs.contains(entry.windowID)
            else { continue }

            if state.setBrowserIcon(
                remembered.icon,
                for: entry.windowID,
                presentationID: presentationID,
                isComposed: true,
                siteTint: remembered.tint
            ) != nil {
                restored += 1
            }
        }

        if restored > 0 {
            Log.registry.info("restored \(restored) verified browser icons without asking a browser")
        }
    }

    private func rememberBrowserIcon(
        _ icon: NSImage,
        for windowID: CGWindowID,
        title: String,
        tint: IconTint?
    ) {
        browserIconsByWindowID[windowID] = CachedBrowserIcon(
            title: title,
            icon: icon,
            tint: tint
        )
        browserIconOrder.removeAll { $0 == windowID }
        browserIconOrder.append(windowID)

        while browserIconsByWindowID.count > Self.maximumRememberedBrowserIcons,
              let oldest = browserIconOrder.first {
            browserIconOrder.removeFirst()
            browserIconsByWindowID.removeValue(forKey: oldest)
        }
    }

    private func forgetBrowserIcon(for windowID: CGWindowID) {
        browserIconsByWindowID.removeValue(forKey: windowID)
        browserIconOrder.removeAll { $0 == windowID }
    }

    /// Refresh active-tab URLs for browsers whose Automation access has already succeeded.
    ///
    /// Called only after the panel is visible. `allowPermissionPrompt: false` makes this a no-op
    /// for a browser that has not been inspected before, so a consent dialog can never interrupt
    /// the presentation. Favicons arrive as fixed-size image replacements and do not relayout it.
    private func refreshBrowserWindows(for entries: [WindowEntry], presentationID: Int) {
        inspectBrowserWindows(
            entries,
            allowPermissionPrompt: false,
            presentationID: presentationID
        )
    }

    /// Ask newly encountered browsers about their windows after the overlay has gone away.
    ///
    /// The first Apple Event to a browser may show macOS's Automation consent dialog. A short
    /// grace period lets a rapid reopen cancel this task before that event is sent. Successful
    /// normal-window favicon requests also prewarm the memory cache for the next presentation;
    /// private and unknown browser modes are never sent to the favicon service.
    private func learnBrowserWindows(for entries: [WindowEntry]) {
        let candidates = browserWindowCandidates(in: entries)
        guard !candidates.isEmpty else { return }

        // Browsing mode never changes for a window. Once every candidate has been settled, the
        // post-presentation refresh owns dynamic URL updates and this prompt-capable path can stop.
        guard candidates.contains(where: {
            !incognitoResolvedWindowIDs.contains($0.windowID)
        }) else { return }

        inspectBrowserWindows(
            candidates,
            allowPermissionPrompt: true,
            presentationID: nil
        )
    }

    private func browserWindowCandidates(in entries: [WindowEntry]) -> [WindowEntry] {
        let browsers = Set(
            BrowserTab.Browser.allCases.filter(\.needsWindowInspection).map(\.bundleIdentifier)
        )
        return entries.filter { entry in
            entry.isWindow && entry.bundleIdentifier.map(browsers.contains) == true
        }
    }

    private func invalidateBrowserInspections() {
        browserInspectionGeneration &+= 1
        browserAuthorizationTask?.cancel()
        browserAuthorizationTask = nil
    }

    /// Match the browser and window-server descriptions once, then derive both static private
    /// mode and dynamic favicon work from those exact pairs.
    private func inspectBrowserWindows(
        _ entries: [WindowEntry],
        allowPermissionPrompt: Bool,
        presentationID: Int?,
        userRequested: Bool = false
    ) {
        let candidates = browserWindowCandidates(in: entries)
        guard !candidates.isEmpty else { return }

        // A "Search through Tabs" click must not cancel the presentation inspect that
        // is already pairing these windows — that is what left the overlay waiting.
        if !userRequested {
            browserInspectionGeneration &+= 1
        }
        let generation = browserInspectionGeneration
        let delay = (!userRequested && allowPermissionPrompt)
            ? Self.browserAuthorizationDelayNanoseconds
            : 0
        // Visible refreshes are allowed two short retries. They repair transient AppleScript,
        // title/frame matching and active-URL misses without carrying an unverified favicon from
        // an earlier presentation. The prompt-capable dismissal path remains single-shot, except
        // when the user asked for tabs: they are waiting, so inspect while the overlay is up.
        let retryDelays: [UInt64] = (allowPermissionPrompt && !userRequested)
            ? []
            : [180_000_000, 420_000_000]

        let task = Task { [weak self, browserTabs, browserFavicons] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard let self, self.browserInspectionGeneration == generation else { return }
            if !userRequested {
                guard !allowPermissionPrompt || !self.state.isVisible else { return }
            }

            var pending = candidates

            for attempt in 0...retryDelays.count {
                guard self.browserInspectionGeneration == generation else { return }
                if !userRequested {
                    guard !allowPermissionPrompt || !self.state.isVisible else { return }
                }

                if allowPermissionPrompt {
                    self.isBrowserAuthorizationInFlight = true
                }
                let scripted = await browserTabs.windows(
                    allowPermissionPrompt: allowPermissionPrompt
                )
                if allowPermissionPrompt {
                    self.isBrowserAuthorizationInFlight = false
                    if self.browserInspectionGeneration == generation {
                        self.browserAuthorizationTask = nil
                    }
                }

                // NSAppleScript is synchronous once it starts, so cancellation is enforced here,
                // before stale work can alter mode caches or launch network requests.
                guard self.browserInspectionGeneration == generation else { return }

                let currentWindowIDs = Set(self.state.allWindowEntries.map(\.windowID))
                let paired = IncognitoMatcher.matchedWindows(
                    entries: pending,
                    scripted: scripted
                )
                let matched = paired.filter { currentWindowIDs.contains($0.key) }
                if paired.count != matched.count {
                    // Separates "could not pair" from "paired, then discarded as stale". The two
                    // have nothing in common except the symptom.
                    Log.registry.info("""
                        \(paired.count - matched.count) of \(paired.count) paired browser \
                        windows discarded as no longer current
                        """)
                }

                // Retained so a card can be tied back to the browser's own window id, which is the
                // only identifier its tab list is numbered by. Without it a window card cannot be
                // asked "which of these tabs are yours".
                for (windowID, window) in matched {
                    self.scriptedWindowIdentifiers[windowID] = window.identifier
                }
                self.applyPendingTabSearch()
                if !matched.isEmpty {
                    let incognito = Set(
                        matched.compactMap { windowID, window in
                            window.isIncognito ? windowID : nil
                        }
                    )
                    let explicitlyNormal = Set(
                        matched.compactMap { windowID, window in
                            window.allowsFaviconRequest ? windowID : nil
                        }
                    )
                    // A CGWindowID may be recycled. An explicit current normal result clears an
                    // older private classification; unknown modes fail closed and clear nothing.
                    self.knownIncognitoWindowIDs.subtract(explicitlyNormal)
                    self.knownIncognitoWindowIDs.formUnion(incognito)
                    self.incognitoResolvedWindowIDs.formUnion(matched.keys)
                    // A window that turns out to be private must not keep a remembered site icon,
                    // whether it was recycled or reclassified.
                    for windowID in incognito {
                        self.forgetBrowserIcon(for: windowID)
                    }

                    if let presentationID,
                       self.state.isVisible,
                       self.state.presentationID == presentationID {
                        let visibleIDs = Set(self.state.allWindowEntries.map(\.windowID))
                        self.state.incognitoWindowIDs = self.knownIncognitoWindowIDs
                            .intersection(visibleIDs)
                    }

                    // Counts on both sides, not just the matches. "1 matched" alone cannot
                    // distinguish a browser window missing from the switcher's own list from one
                    // that is present but could not be paired with the browser's description of
                    // it — and those are unrelated faults with unrelated fixes.
                    Log.registry.info("""
                        inspected \(matched.count) of \(candidates.count) browser windows \
                        (\(scripted.count) reported by their browsers), \
                        \(incognito.count) incognito
                        """)

                    if matched.count < candidates.count {
                        // Which signal failed, for the windows that did not pair. Titles are not
                        // logged — they are the user's browsing — so this reports only whether
                        // each signal agreed with anything, which is what separates "the two APIs
                        // disagree about the title" from "several windows look identical".
                        let unmatched = candidates.filter { matched[$0.windowID] == nil }
                        for entry in unmatched {
                            let sameBrowser = scripted.filter {
                                $0.browser.bundleIdentifier == entry.bundleIdentifier
                            }
                            let titleAgreements = sameBrowser.filter {
                                let ours = entry.title
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                let theirs = $0.title
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                return !ours.isEmpty && ours == theirs
                            }.count
                            let frameAgreements = sameBrowser.filter {
                                abs($0.frame.minX - entry.frame.minX)
                                    <= IncognitoMatcher.frameTolerance
                                    && abs($0.frame.minY - entry.frame.minY)
                                        <= IncognitoMatcher.frameTolerance
                                    && abs($0.frame.width - entry.frame.width)
                                        <= IncognitoMatcher.frameTolerance
                                    && abs($0.frame.height - entry.frame.height)
                                        <= IncognitoMatcher.frameTolerance
                            }.count
                            Log.registry.info("""
                                unpaired browser window \(entry.windowID): \
                                \(sameBrowser.count) same-browser records, \
                                \(titleAgreements) agree on title, \
                                \(frameAgreements) agree on frame, \
                                our title \(entry.title.count) chars, \
                                our frame \(entry.frame.debugDescription, privacy: .public)
                                """)
                        }
                        for window in scripted where !matched.values.contains(window) {
                            Log.registry.info("""
                                unpaired browser record \(window.identifier): \
                                their title \(window.title.count) chars, \
                                their frame \(window.frame.debugDescription, privacy: .public)
                                """)
                        }
                    }

                    var completedWindowIDs: Set<CGWindowID> = []
                    for (windowID, browserWindow) in matched {
                        // Private and unknown modes are complete app-icon-only results. A normal
                        // record with no URL stays pending because that read can fail transiently.
                        guard browserWindow.allowsFaviconRequest else {
                            completedWindowIDs.insert(windowID)
                            continue
                        }
                        guard !self.knownIncognitoWindowIDs.contains(windowID),
                              let activeTabURL = browserWindow.activeTabURL
                        else { continue }

                        completedWindowIDs.insert(windowID)
                        // Named before the favicon is even requested. The host is already known
                        // here, and a site whose icon cannot be fetched is still worth naming —
                        // which is most of them on a first visit.
                        if let presentationID {
                            self.state.setSiteHost(
                                BrowserTab.host(ofURL: activeTabURL),
                                for: windowID,
                                presentationID: presentationID
                            )
                        }
                        Task { [weak self, browserFavicons] in
                            guard let self,
                                  self.browserInspectionGeneration == generation
                            else { return }

                            guard let favicon = await browserFavicons.favicon(
                                for: activeTabURL,
                                prefetch: presentationID == nil
                            ) else {
                                Log.registry.info("""
                                    no site icon resolved for a browser window; \
                                    keeping its application icon
                                    """)
                                return
                            }

                            // Deliberately not gated on the inspection generation. A generation
                            // change means "do not touch the current presentation", not "this
                            // window's active tab was wrong": dismissing the overlay or opening it
                            // again both bump it, and discarding a resolved icon there is what made
                            // the composed icon come and go. Publication below is still gated, and
                            // reuse is revalidated by title, so recording it cannot show a stale
                            // site for a tab that has since changed.

                            let image = NSImage(
                                cgImage: favicon,
                                size: NSSize(width: favicon.width, height: favicon.height)
                            )
                            image.isTemplate = false

                            // Recorded before any publication decision, for the same reason: an
                            // Apple Event can take seconds, by which time a quick switch has
                            // already closed the overlay.
                            guard let entry = self.state.allWindowEntries.first(where: {
                                $0.windowID == windowID
                            }),
                            !self.knownIncognitoWindowIDs.contains(windowID)
                            else { return }

                            let composed = entry.applicationIcon.map {
                                BrowserWindowIcon.layered(siteIcon: image, browserIcon: $0)
                            } ?? image
                            // Sampled from the site icon rather than the composition, which is
                            // mostly browser: the site is what distinguishes one browser window
                            // from the next.
                            let siteTint = IconTint.sampled(from: image)
                            self.rememberBrowserIcon(
                                composed,
                                for: windowID,
                                title: entry.title,
                                tint: siteTint
                            )

                            // A dismissal-time lookup exists only to warm the caches.
                            guard let presentationID else { return }

                            if self.state.setBrowserIcon(
                                composed,
                                for: windowID,
                                presentationID: presentationID,
                                isComposed: true,
                                siteTint: siteTint
                            ) != nil {
                                Log.registry.info("published a layered site icon for a browser window")
                            } else {
                                Log.registry.info("""
                                    a site icon arrived after its presentation ended; \
                                    it will show on the next one
                                    """)
                            }
                        }
                    }
                    pending.removeAll { completedWindowIDs.contains($0.windowID) }
                }

                guard !pending.isEmpty, attempt < retryDelays.count else { return }
                do {
                    try await Task.sleep(nanoseconds: retryDelays[attempt])
                } catch {
                    return
                }
            }
        }

        if allowPermissionPrompt {
            browserAuthorizationTask?.cancel()
            browserAuthorizationTask = task
        }
    }

    private func startCaptures(for entries: [WindowEntry], backingScale: CGFloat) {
        let windows = entries.filter(\.isWindow)
        guard !windows.isEmpty else { return }

        // Two ways to end up with no use for a screenshot: Icon View draws application icons
        // by choice, and the spiral cannot show a screenshot at all because its seats are
        // wedges. Either way capturing is work whose result is thrown away — and between them
        // they are why neither needs Screen Recording.
        guard state.viewMode.usesThumbnails, state.layoutStyle.canShowThumbnails else { return }
        // Requirement 10.8: without Screen Recording, skip capture entirely and let
        // the cards keep their app icons rather than burning time on calls that fail.
        guard permissions.screenRecordingGranted else { return }

        Task { [weak self, thumbnails] in
            let token = await thumbnails.beginGeneration()
            await MainActor.run { self?.captureToken = token }

            await thumbnails.captureStills(
                for: windows,
                scale: backingScale,
                token: token
            ) { windowID, image in
                self?.state.setThumbnail(image, for: windowID)
            }
        }

        refreshSelectedPreview(backingScale: backingScale)
    }

    /// Requirement 3.4 plus Requirement 9.6–9.8: high-resolution still for the
    /// selected card, then a bounded live refresh of just that card.
    private func refreshSelectedPreview(backingScale: CGFloat) {
        guard state.viewMode.usesThumbnails, state.layoutStyle.canShowThumbnails else { return }
        guard permissions.screenRecordingGranted,
              let entry = state.selectedEntry,
              entry.isWindow else { return }
        let token = captureToken

        Task { [weak self, thumbnails] in
            await thumbnails.captureSelectedPreview(
                for: entry,
                scale: backingScale,
                token: token
            ) { windowID, image in
                self?.state.setThumbnail(image, for: windowID)
            }
            await thumbnails.startLiveStream(
                for: entry,
                scale: backingScale,
                token: token
            ) { windowID, image in
                self?.state.setThumbnail(image, for: windowID)
            }
        }
    }

    // MARK: - Dismissal

    /// Single exit point. `entry == nil` means "leave the frontmost window alone"
    /// (Requirement 8.1–8.4).
    /// - Parameter activationDelay: how long to hold the raise back so the switch animation is
    ///   visible first. Zero means the previous behaviour: raise immediately.
    private func dismiss(activating entry: WindowEntry?, activationDelay: TimeInterval = 0) {
        let wasVisible = state.isVisible

        // Requirement 7.1: the overlay goes away before activation work starts, so
        // the switch reads as instant.
        panel?.dismiss()
        state.isVisible = false
        triggerMonitor.isSearchActive = false
        triggerMonitor.setOverlayTapEnabled(false)
        triggerMonitor.clearHeldState()
        stopHoverTracking()
        removeClickMonitors()
        hoveredIndex = nil
        hoverHoldPoint = nil
        invalidateBrowserTabLoad()
        pendingSearchConfirmation = nil
        activateAsSoonAsReady = false
        state.isPersistent = false
        // Reset so a stray press starts a fresh presentation rather than being read as
        // another confirmation.
        presentationMode = .hold
        if wasVisible {
            suppressTriggerUntil = DispatchTime.now() + Self.reopenSuppression
        }

        if let entry {
            performActivation(entry, afterDelay: activationDelay)
        }

        // Requirement 8.5, 8.6.
        Task { [thumbnails] in
            await thumbnails.teardown()
        }

        // Before the entries are released: asked now, with the overlay gone, so the Automation
        // consent dialog cannot take focus away from a presentation. Use the unfiltered window
        // snapshot rather than an active search's subset.
        if wasVisible {
            learnBrowserWindows(for: state.allWindowEntries)
        }
        state.releaseThumbnails()

        if wasVisible {
            Log.overlay.debug("overlay dismissed\(entry == nil ? " without switching" : "", privacy: .public)")
        }
    }

    private func performActivation(_ entry: WindowEntry, afterDelay delay: TimeInterval = 0) {
        // Stamped now rather than with the raise, so MRU ordering is already correct if the user
        // re-triggers during the delay. Requirement 2.2's reason for stamping eagerly applies
        // just as much when the raise itself is deferred.
        if entry.isWindow {
            mruTracker.recordActivation(windowID: entry.windowID)
        }

        guard delay > 0 else {
            raise(entry)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.raise(entry)
            }
        }
    }

    private func raise(_ entry: WindowEntry) {
        do {
            let raisedExactWindow = try activation.activate(
                entry,
                canUseAccessibility: permissions.accessibilityGranted,
                displayLayout: state.displayLayout,
                lookingAt: lookingAtDisplay()
            )
            if !raisedExactWindow {
                Log.activation.debug("activated app only for \(entry.applicationName, privacy: .public)")
            }
        } catch ActivationService.Failure.windowGone {
            // Requirement 7.7, 7.8. The app-level fallback now lives inside
            // `activate` for a window whose handle died; this is only reached if
            // something still throws.
            Log.activation.info("target window vanished before activation; leaving focus alone")
            mruTracker.forget(windowID: entry.windowID)
        } catch ActivationService.Failure.applicationGone {
            if let application = entry.launchableApplication {
                discardUnavailableApplication(application)
                NSSound.beep()
                Log.activation.info("installed application is no longer available at its indexed path")
            } else {
                Log.activation.info("target application quit before activation; leaving focus alone")
                if entry.isWindow {
                    mruTracker.forget(windowID: entry.windowID)
                }
            }
        } catch {
            Log.activation.error("activation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleApplicationLaunchFailure(
        _ application: LaunchableApplication,
        error: Error
    ) {
        discardUnavailableApplication(application)
        NSSound.beep()
        Log.activation.error(
            "removed unlaunchable application \(application.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    private func discardUnavailableApplication(_ application: LaunchableApplication) {
        applicationCatalog.remove(application)
        state.removeApplication(id: application.id)
    }

    private func resolvePendingSearchConfirmationIfReady() {
        guard let pending = pendingSearchConfirmation else { return }
        guard state.isVisible,
              state.presentationID == pending.presentationID,
              state.searchQuery == pending.query else {
            pendingSearchConfirmation = nil
            return
        }
        guard !state.isResolvingSearch else { return }

        pendingSearchConfirmation = nil
        if pending.intent == .firstWebResult {
            openFirstWebResult()
            return
        }
        commitSelection(intent: pending.intent)
    }

    private func commitSelection(intent: ConfirmationIntent = .selection) {
        if state.isResolvingSearch {
            pendingSearchConfirmation = PendingSearchConfirmation(
                presentationID: state.presentationID,
                query: state.searchQuery,
                intent: intent
            )
            Log.overlay.debug("queued confirmation until local search sources settle")
            return
        }
        pendingSearchConfirmation = nil

        // Decided by `ConfirmationTarget` rather than by a chain of conditions here. The chain it
        // replaces put the Return-only web fallback ahead of the selected entry, so a selected
        // "Prompt on ChatGPT" opened a Google search instead — see that type for the full account.
        let entry: WindowEntry
        switch ConfirmationTarget.resolve(
            isReturn: intent == .returnKey,
            selectedEntry: state.selectedEntry,
            canOfferWebSearch: state.canOfferWebSearch,
            query: state.searchQuery
        ) {
        case .open(let destination):
            openInDefaultBrowser(destination)
            return
        case .dismiss:
            dismiss(activating: nil)
            return
        case .activate(let selected):
            entry = selected
        }

        // Planned before dismissal, because it needs the card's frame while the panel is still
        // on screen, and the thumbnail before `releaseThumbnails` drops it.
        let transition = planTransition(for: entry)
        let ghostImage = state.thumbnails[entry.windowID]
        let ghostIcon = state.displayIcon(for: entry)

        // The overlay still goes away at once (Requirement 7.1); only the raise waits, and only
        // when there is an animation to see.
        dismiss(activating: entry, activationDelay: transition?.activationDelay ?? 0)

        if let transition {
            runTransition(transition, for: entry, image: ghostImage, icon: ghostIcon)
        }
    }

    // MARK: - Switch animation

    /// Work out where the ghost should fly from and to.
    ///
    /// Returns `nil` whenever the animation would mislead rather than explain:
    ///
    /// - **Tabs** have no window frame to fly to.
    /// - **Minimized windows** report a stale or empty frame; the window is going to the Dock's
    ///   idea of somewhere, not to that rectangle.
    /// - **Windows on another Space** are about to trigger a Space switch, and a ghost flying
    ///   across a desktop change looks like a glitch.
    /// - **Reduce Motion**, handled inside `WindowTransition.plan`.
    private func planTransition(for entry: WindowEntry) -> WindowTransition? {
        guard entry.isWindow, !entry.isMinimized, entry.isOnActiveSpace else { return nil }
        guard let panel, state.isVisible else { return nil }
        guard let index = state.entries.firstIndex(where: { $0.id == entry.id }) else { return nil }

        let layout = state.layout
        guard let card = layout.positionedCards(scrollOffset: state.scrollOffset)
            .first(where: { $0.index == index })
        else { return nil }

        // The card's rectangle is in panel top-left coordinates; the ghost is placed in AppKit
        // screen coordinates.
        let drawn = layout.drawnFrame(for: card, selectedScale: state.selectedScale)
        let cardFrame = CGRect(
            x: panel.frame.minX + drawn.minX,
            y: panel.frame.maxY - drawn.maxY,
            width: drawn.width,
            height: drawn.height
        )

        guard let primaryHeight = Self.primaryDisplayHeight() else { return nil }
        let targetFrame = ScreenGeometry.appKitFrame(
            fromQuartz: entry.frame,
            primaryHeight: primaryHeight
        )

        return WindowTransition.plan(
            cardFrame: cardFrame,
            targetFrame: targetFrame,
            displayFrames: NSScreen.screens.map(\.frame),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func runTransition(
        _ transition: WindowTransition,
        for entry: WindowEntry,
        image: CGImage?,
        icon: NSImage?
    ) {
        let ghost = TransitionPanel(
            image: image,
            icon: icon,
            startFrame: transition.start
        )
        // Held so the panel is not deallocated mid-animation, and released when it finishes.
        activeTransition = ghost

        Log.overlay.debug("""
            switch animation \(transition.crossesDisplay ? "across displays" : "in place", privacy: .public), \
            moving \(transition.direction.rawValue, privacy: .public)
            """)

        ghost.run(to: transition.end, duration: transition.duration) { [weak self] in
            self?.activeTransition = nil
        }
    }

    /// The main display's height, which is the axis both coordinate systems are flipped about.
    private static func primaryDisplayHeight() -> CGFloat? {
        // `screens.first` is the display whose origin is (0, 0) — the one with the menu bar.
        guard let primary = NSScreen.screens.first else { return nil }
        return primary.frame.maxY
    }

    /// Briefly ignore trigger presses after a presentation ends.
    ///
    /// Defence in depth alongside the dedup in `TriggerMonitor`. Two independent input
    /// sources (the event tap and the raw HID stream) report the same physical button
    /// with no ordering guarantee between them, and the visible cost of a stray
    /// duplicate is the strip reopening the instant it was dismissed. Short enough that
    /// a deliberate second tap still registers.
    private static let reopenSuppression: TimeInterval = 0.12
    private var suppressTriggerUntil: DispatchTime?

    private var isTriggerSuppressed: Bool {
        guard let suppressTriggerUntil else { return false }
        if DispatchTime.now() < suppressTriggerUntil { return true }
        self.suppressTriggerUntil = nil
        return false
    }

    // MARK: - Hover tracking

    private func startHoverTracking() {
        stopHoverTracking()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func sampleHover() {
        guard state.isVisible, let panel, !state.entries.isEmpty else { return }
        let point = NSEvent.mouseLocation
        let slot = shortcutSlot(atScreenPoint: point, panel: panel)
        if state.hoveredSlot != slot { state.hoveredSlot = slot }
        if let dragging = state.draggingSlot {
            trackSlotDrag(from: dragging, at: point, panel: panel)
            return
        }
        let index = cardIndex(atScreenPoint: point, panel: panel)

        updateCloseButtonHover(at: point, panel: panel)

        // A keystroke has chosen the selection and the pointer has not moved since, so this sample
        // is the old position speaking again rather than the user pointing at anything.
        if let hold = hoverHoldPoint {
            guard abs(point.x - hold.x) >= Self.hoverReleaseDistance
                    || abs(point.y - hold.y) >= Self.hoverReleaseDistance
            else { return }
            hoverHoldPoint = nil
        }

        guard index != hoveredIndex else { return }
        hoveredIndex = index

        // Requirement 4.7.
        if let index {
            let previousSelection = state.selectedIndex
            state.setSelection(index)
            if state.selectedIndex != previousSelection {
                onSelectionChanged()
            }
        }
    }

    /// Track which close affordance the cursor is on, so that one can light up.
    private func updateCloseButtonHover(at point: CGPoint, panel: OverlayPanel) {
        var hovered: Int?

        if panel.frame.contains(point) {
            let pointInPanel = CGPoint(
                x: point.x - panel.frame.minX,
                y: point.y - panel.frame.minY
            )
            if case .close(let index) = state.layout.target(
                atPanelPoint: pointInPanel,
                scrollOffset: state.scrollOffset,
                selectedScale: state.selectedScale
            ), state.entries.indices.contains(index),
               state.canClose(state.entries[index]) {
                hovered = index
            }
        }

        if state.hoveredCloseButtonIndex != hovered {
            state.hoveredCloseButtonIndex = hovered
        }
    }

    /// SPIKE. A secondary click on a card opens a context menu for that window.
    ///
    /// Toggle mode only, and that is not a simplification: in hold mode the trigger button is still
    /// down, so there is no hand free to click a menu item with.
    ///
    /// The open question this exists to answer is whether an `NSMenu` can be driven at all from a
    /// panel that is deliberately never key and belongs to an application that is never active. Every
    /// step logs, so a failure says which step failed rather than "the menu did not work".
    func rightMousePressed(atScreenPoint point: CGPoint) {
        // Before anything else, including the hit test.
        //
        // A right-click anywhere closes an open menu, whether or not it lands on another card, which
        // is what the pointer being somewhere else already means. Doing this after the hit test left
        // the old menu open whenever the new click missed a card — and a menu this tall covers several
        // of them, so missing was easy.
        if let openContextMenu {
            Log.overlay.info("right-click while a menu was open; closing it")
            openContextMenu.cancelTracking()
            self.openContextMenu = nil
        }

        guard state.isVisible, let panel else { return }
        if let slot = shortcutSlot(atScreenPoint: point, panel: panel) {
            showSlotMenu(slot, at: point)
            return
        }
        guard let index = cardIndex(atScreenPoint: point, panel: panel),
              index < state.entries.count
        else {
            Log.overlay.info("right-click inside the panel but not on a card")
            return
        }

        let entry = state.entries[index]
        Log.overlay.info("""
            right-click on card \(index, privacy: .public) \
            (\(entry.applicationName, privacy: .public)); opening context menu
            """)



        // Selection follows the right-click, so the menu visibly belongs to a card.
        state.setSelection(index)
        holdHoverUntilPointerMoves()

        // Right-clicking promotes the presentation to persistent, exactly as a tap does.
        //
        // The first attempt at this *refused* to open a menu unless the overlay was already
        // persistent, reasoning that a held trigger button leaves no hand free. Every right-click in
        // testing was rejected on that basis. The reasoning was also backwards: reaching for the
        // secondary button is an explicit "I want to do something to this card", which is the same
        // signal a tap gives. Refusing it is what "nothing happens on right click" was.
        //
        // Promoting also protects the menu. Left in hold mode, releasing the trigger would commit the
        // selection and tear the overlay down from under the open menu.
        if !state.isPersistent {
            presentationMode = .toggle
            state.isPersistent = true
            activateAsSoonAsReady = false
            Log.overlay.info("right-click promoted the overlay to persistent")
        }

        let rows = CardMenu.rows(for: entry, context: menuContext(for: entry))
        guard !rows.isEmpty else {
            Log.overlay.info("no menu for this card kind")
            return
        }

        // The window's picture has to be in hand before the menu opens, which is why this hands off
        // to a task instead of popping the menu up here.
        //
        // `popUp` blocks the main thread for the whole tracking loop, so anything main-actor bound —
        // including the completion of a capture started a moment earlier — cannot run until the menu
        // has closed. That is not a race to be tightened but a certainty, and the first attempt at
        // this filled in nothing: every capture it took was logged arriving "after its menu closed"
        // and discarded. Awaiting first costs a short delay before the menu appears, and the
        // selection has already moved to the card, so the click is not left unacknowledged.
        Task { [weak self] in
            guard let self else { return }
            let preview = await self.contextMenuPreview(for: entry)
            // The window can go away while it is being photographed.
            guard self.state.isVisible, self.state.entries.contains(where: { $0.id == entry.id }) else {
                Log.overlay.info("context menu abandoned: its card left the list during the capture")
                return
            }
            self.presentContextMenu(for: entry, rows: rows, at: point, preview: preview)
        }
    }

    /// Build and run the menu. Separate from `rightMousePressed` only because the preview must be
    /// awaited between the two, and everything from here on blocks until the menu closes.
    private func presentContextMenu(
        for entry: WindowEntry,
        rows: CardMenu.Rows,
        at point: CGPoint,
        preview: CGImage?
    ) {
        guard let panel else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        // One hover model for the whole menu, keyed on the action rather than on a position, so the
        // corner groups and the row below cannot each think their own first glyph is hovered.
        let hover = CardMenuHoverModel()

        menu.addItem(
            headerItem(for: entry, preview: preview, rows: rows, hover: hover, menu: menu)
        )

        // Two things have to be held off for the whole tracking loop, and getting only the first of
        // them right is what made the menu open but never register a choice.
        //
        // Dismissal, because the overlay closes on a primary click and picking a menu item is one.
        // And the event tap's *consumption* of primary clicks, because it sits in front of the menu:
        // suppressing our own handling is not enough while the click is still being swallowed before
        // the menu can see it.
        isShowingContextMenu = true
        triggerMonitor.contextMenuIsTracking = true
        openContextMenu = menu
        defer {
            isShowingContextMenu = false
            triggerMonitor.contextMenuIsTracking = false
            // Only if it is still this menu: a right-click on another card has already replaced the
            // handle, and clearing it here would leave the new menu unclosable by the next one.
            if openContextMenu === menu { openContextMenu = nil }
            Log.overlay.info("context menu closed; overlay still visible: \(self.state.isVisible, privacy: .public)")
        }

        // Positioned in screen coordinates, with no view to interpret them.
        //
        // Passing `panel.contentView` looked like the natural thing and put the menu somewhere else
        // entirely, because the point then has to be in *that view's* coordinate space. The content
        // view is an `NSHostingView`, and SwiftUI hosting views are flipped — origin at the top-left,
        // y increasing downward — while `NSEvent.mouseLocation` and `panel.frame` are both bottom-left
        // screen coordinates. Subtracting the panel's origin produced a y measured from the wrong
        // edge, so the error grew with distance from the panel's vertical centre.
        //
        // Handing `nil` for the view makes `popUp` read the point as screen coordinates, which is
        // exactly what the click already is. No conversion, so no coordinate space to get wrong.
        Log.overlay.info("""
            context menu at screen \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public); \
            contentView flipped: \(panel.contentView?.isFlipped ?? false, privacy: .public)
            """)
        let shown = menu.popUp(positioning: nil, at: point, in: nil)
        Log.overlay.info("context menu popUp returned \(shown, privacy: .public)")
    }

    /// What every glyph in the menu does when clicked, wherever it is drawn.
    private func menuAction(
        for entry: WindowEntry,
        menu: NSMenu,
        hover: CardMenuHoverModel
    ) -> (CardMenuItem) -> Void {
        { [weak self, weak menu] action in
            Log.overlay.info("menu glyph chosen: \(String(describing: action), privacy: .public)")
            // Pause / next stay in the open menu so the transport can be used as a player.
            // Everything else ends tracking first, because those actions tear the overlay
            // down and must not do it underneath a tracking loop.
            if action.keepsMenuOpen {
                if action == .pausePlayback { hover.togglePlaybackPaused() }
                self?.perform(action, onEntry: entry.id)
                return
            }
            menu?.cancelTracking()
            self?.perform(action, onEntry: entry.id)
        }
    }

    /// What a menu item carries with it, so the action is not resolved against a selection that may
    /// have moved since the menu opened.
    private final class CardMenuChoice: NSObject {
        let item: CardMenuItem
        let entryID: String

        init(item: CardMenuItem, entryID: String) {
            self.item = item
            self.entryID = entryID
        }
    }

    /// The menu's heading: a preview of the window and the facts worth knowing before acting on it.
    ///
    /// A hosted view rather than a titled item, for two reasons. It is what lets the preview and the
    /// aligned fact list exist at all, and it is what stops the window title from setting the menu's
    /// width — an `NSMenu` sizes itself to its widest item, so a long title used to stretch every
    /// short action item alongside it.
    private func headerItem(
        for entry: WindowEntry,
        preview: CGImage?,
        rows: CardMenu.Rows,
        hover: CardMenuHoverModel,
        menu: NSMenu
    ) -> NSMenuItem {
        let scriptedID = scriptedWindowIdentifiers[entry.windowID]
        let details = CardDetails.make(
            entry: entry,
            siteHost: state.siteHost(for: entry),
            tabCount: scriptedID.flatMap { identifier in
                state.hasLoadedTabs ? state.tabCount(forWindowIdentifier: identifier) : nil
            },
            windowPosition: state.windowPosition(for: entry),
            isIncognito: state.isIncognito(entry),
            isPlayingAudio: state.isPlayingAudio(entry),
            isUsingMicrophone: state.isUsingMicrophone(entry),
            now: Date().timeIntervalSinceReferenceDate
        )

        Log.overlay.info("""
            menu header: \(details.rows.count, privacy: .public) facts \
            [\(details.rows.map(\.label).joined(separator: ", "), privacy: .public)], \
            preview: \(preview != nil, privacy: .public)
            """)

        let header = NSHostingView(
            rootView: CardMenuHeaderView(
                details: details,
                thumbnail: preview,
                icon: entry.applicationIcon,
                windowControls: rows.windowControls,
                media: rows.media,
                contents: rows.contents,
                moveResize: rows.moveResize,
                fillArrange: rows.fillArrange,
                placement: rows.placement,
                hover: hover,
                onAction: menuAction(for: entry, menu: menu, hover: hover)
            )
        )
        // A menu item's view is not laid out by the menu, so it has to arrive at its final size.
        // `fittingSize` resolves the height the fixed-width content settled on.
        header.frame = CGRect(origin: .zero, size: header.fittingSize)

        let item = NSMenuItem()
        item.view = header
        // Enabled, where this used to be disabled. The controls now live inside this block, and a
        // disabled item does not track at all — its view would never see a click. The inert parts of
        // the view simply do nothing when clicked, as a disabled menu item would.
        item.isEnabled = true

        return item
    }

    /// The picture for the menu's well, captured on demand because the spiral has none cached.
    ///
    /// `OverlayLayoutStyle.canShowThumbnails` is false for both radial windings, and rightly so: a
    /// rectangular screenshot clipped into an annular sector is unreadable, so capturing for those
    /// cards would be work thrown away. But that is a fact about the *seats*, not about the window,
    /// and this menu has a rectangular well to put a capture in. Reading only `state.thumbnails`
    /// meant the spiral — the default arrangement, and the one in use — showed an application icon
    /// here forever, so the preview was decoration rather than the window.
    private func contextMenuPreview(for entry: WindowEntry) async -> CGImage? {
        // A layout that does cache stills has already paid for this one.
        if let cached = state.thumbnails[entry.windowID] { return cached }
        guard permissions.screenRecordingGranted else { return nil }

        let scale = panel?.backingScaleFactor ?? 2
        let started = Date()
        let image = await thumbnails.capturePreview(
            for: entry,
            // Asked for at twice the size it is drawn, so the well is sharp on a Retina display.
            pixelSize: CGSize(
                width: CardMenuHeaderView.previewWidth * scale * 2,
                height: CardMenuHeaderView.previewHeight * scale * 2
            )
        )
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.overlay.info("""
            context menu preview \(image == nil ? "unavailable" : "captured", privacy: .public) \
            in \(elapsed, privacy: .public)ms
            """)
        return image
    }

    private func menuContext(for entry: WindowEntry) -> CardMenu.Context {
        let scriptedID = scriptedWindowIdentifiers[entry.windowID]
        let browser = BrowserTab.Browser.allCases.first {
            $0.bundleIdentifier == entry.bundleIdentifier
        }
        let currentDisplay = state.displayLayout.display(for: entry.frame)
        return CardMenu.Context(
            // An application we can list tabs for *and* have paired to its scripting id. Without
            // the pairing there is no way to say which tabs belong to this window, so the item
            // would scope to nothing.
            // Offered for any scriptable browser, even before this card is paired to a
            // scripting id. Waiting on that pairing is what hid "Search through Tabs" on
            // Chrome windows the matcher had not settled yet. Choosing the item is what
            // fetches the tabs, and pairing can finish after the click.
            hasSearchableTabs: browser != nil,
            knownTabCount: scriptedID.flatMap { identifier in
                state.hasLoadedTabs ? state.tabCount(forWindowIdentifier: identifier) : nil
            },
            isPlayingAudio: state.isPlayingAudio(entry),
            hasAccessibilityElement: entry.axElement != nil,
            isMinimized: entry.isMinimized,
            isFullScreen: Self.windowIsFullScreen(entry),
            otherDisplays: state.displayLayout.displays.filter { $0.number != currentDisplay?.number }
        )
    }

    /// Full Screen is a Space, published as `AXFullScreen`. Filling the usable area is a
    /// different action and still offers this item.
    private static func windowIsFullScreen(_ entry: WindowEntry) -> Bool {
        guard let element = entry.axElement else { return false }
        return AXBridge.bool(element, "AXFullScreen") ?? false
    }

    @objc
    private func cardMenuItemChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? CardMenuChoice else { return }
        perform(choice.item, onEntry: choice.entryID)
    }

    /// One path for both forms the menu takes. A glyph in the actions row and a written line below it
    /// are the same action, so they must not be able to drift into doing different things.
    private func perform(_ item: CardMenuItem, onEntry entryID: String) {
        guard let index = state.entries.firstIndex(where: { $0.id == entryID }) else {
            Log.overlay.info("menu action dropped: its card is no longer in the list")
            return
        }
        let entry = state.entries[index]
        Log.overlay.info("menu action \(String(describing: item), privacy: .public)")

        switch item {
        case .searchWindowTabs:
            searchTabs(of: entry)

        case .minimizeWindow:
            guard let element = entry.axElement else { return }
            AXBridge.setBool(element, kAXMinimizedAttribute as String, true)
            dismiss(activating: nil)

        case .closeWindow:
            closeWindow(at: index)

        case .tileWindow(let tile):
            tileWindow(entry, to: tile)

        case .enterFullScreen:
            enterFullScreen(entry)

        case .exitFullScreen:
            exitFullScreen(entry)

        case .moveToDisplay(let display):
            moveWindow(entry, to: display)

        case .pausePlayback:
            let sent = MediaRemoteBridge.send(.togglePlayPause)
            Log.overlay.info("play/pause sent: \(sent, privacy: .public)")

        case .nextTrack:
            let sent = MediaRemoteBridge.send(.next)
            Log.overlay.info("next track sent: \(sent, privacy: .public)")

        case .previousTrack:
            let sent = MediaRemoteBridge.send(.previous)
            Log.overlay.info("previous track sent: \(sent, privacy: .public)")
        }
    }

    /// Send a window to a region of the screen the user is looking at.
    ///
    /// That is the overlay's display — the one the pointer is on — not the display the
    /// window currently occupies. Tiling a Chrome window that lives on the other monitor
    /// to "left half" of *that* other monitor leaves this one empty, which is the opposite
    /// of putting two windows side by side in front of you.
    ///
    /// Tiled to the screen's *visible* bounds, not its full bounds, or the window slides under the
    /// menu bar and the Dock. `DisplayInfo` carries both, in the same Quartz global space that
    /// `kAXPositionAttribute` speaks, so there is no coordinate conversion left to get wrong here —
    /// it was done once where the two spaces are documented together.
    ///
    /// A Full Screen window occupies a Space, so the frame is applied after leaving it.
    /// That is what lets a window on a live-shared display be tiled or moved off it.
    private func tileWindow(_ entry: WindowEntry, to tile: WindowTile) {
        guard let element = entry.axElement else { return }
        guard let display = state.displayLayout.placementDisplay(
            lookingAt: lookingAtDisplay(),
            windowFrame: entry.frame
        ) else {
            Log.overlay.info("tile dropped: the window is on no active display")
            return
        }

        afterLeavingFullScreenIfNeeded(entry, element: element) { [weak self] in
            self?.applyTile(entry, element: element, tile: tile, display: display)
        }
    }

    private func applyTile(
        _ entry: WindowEntry,
        element: AXUIElement,
        tile: WindowTile,
        display: DisplayInfo
    ) {
        let frame = tile.frame(in: display.visibleBounds)
        let applied = AXBridge.setFrame(element, frame)
        Log.overlay.info("""
            tiled \(entry.applicationName, privacy: .public) \(tile.rawValue, privacy: .public) \
            on screen \(display.number, privacy: .public) to \
            \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public) \
            at \(Int(frame.minX), privacy: .public),\(Int(frame.minY), privacy: .public); \
            accepted: \(applied, privacy: .public)
            """)

        // Read back rather than assume. A window can refuse part of what it was asked for — many have
        // a minimum width, and some are not resizable at all — so the frame recorded here is the one
        // the window actually took, which is what keeps the next right-click's size row honest.
        if let origin = AXBridge.point(element, kAXPositionAttribute as String),
           let size = AXBridge.size(element, kAXSizeAttribute as String) {
            state.setFrame(CGRect(origin: origin, size: size), forWindowID: entry.windowID)
        }

        // Frame first, then raise: the user should see the tiled window come forward, not
        // the old size and then a jump. The overlay stays open so a second tile can be tried.
        bringForward(entry)
    }

    private func enterFullScreen(_ entry: WindowEntry) {
        setFullScreen(entry, true)
    }

    private func exitFullScreen(_ entry: WindowEntry) {
        setFullScreen(entry, false)
    }

    /// Full Screen is a Space, not a frame, so it is a boolean on the window rather than a resize.
    ///
    /// The overlay will dismiss itself when the Space change lands, which is the right follow-through:
    /// the window has left (or returned to) the desktop the overlay was drawn on.
    private func setFullScreen(_ entry: WindowEntry, _ fullScreen: Bool) {
        guard let element = entry.axElement else { return }
        let applied = AXBridge.setBool(element, "AXFullScreen", fullScreen)
        Log.overlay.info("""
            full screen \(fullScreen ? "enter" : "exit") \
            \(entry.applicationName, privacy: .public); \
            accepted: \(applied, privacy: .public)
            """)
    }

    /// How long a tile may wait for Full Screen to finish leaving its Space.
    private static let fullScreenExitTimeout: TimeInterval = 2.0

    /// Leave Full Screen if needed, then run `then`. The Space change dismisses the
    /// overlay; the follow-through still has to fire, or Move to Display from a
    /// shared screen would never land.
    private func afterLeavingFullScreenIfNeeded(
        _ entry: WindowEntry,
        element: AXUIElement,
        then: @escaping () -> Void
    ) {
        guard Self.windowIsFullScreen(entry) else {
            then()
            return
        }

        fullScreenFollowThroughGeneration &+= 1
        let generation = fullScreenFollowThroughGeneration
        setFullScreen(entry, false)

        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.fullScreenExitTimeout)
            while Date() < deadline {
                guard let self, self.fullScreenFollowThroughGeneration == generation else { return }
                if !(AXBridge.bool(element, "AXFullScreen") ?? false) {
                    // The restored desktop frame lands a beat after the flag flips.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard self.fullScreenFollowThroughGeneration == generation else { return }
                    then()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, self.fullScreenFollowThroughGeneration == generation else { return }
            Log.overlay.info("full screen exit wait elapsed; placing the window anyway")
            then()
        }
    }

    /// Centre the window on another display, shrinking it if that display is smaller.
    private func moveWindow(_ entry: WindowEntry, to display: DisplayInfo) {
        guard let element = entry.axElement else { return }
        afterLeavingFullScreenIfNeeded(entry, element: element) { [weak self] in
            self?.applyMove(entry, element: element, to: display)
        }
    }

    private func applyMove(_ entry: WindowEntry, element: AXUIElement, to display: DisplayInfo) {
        let size = AXBridge.size(element, kAXSizeAttribute as String) ?? entry.frame.size
        let frame = display.frameForMovedWindow(size: size)
        let applied = AXBridge.setFrame(element, frame)
        Log.overlay.info("""
            moved \(entry.applicationName, privacy: .public) to \
            screen \(display.number, privacy: .public) \
            \(display.name, privacy: .public) at \
            \(Int(frame.minX), privacy: .public),\(Int(frame.minY), privacy: .public) \
            \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public); \
            accepted: \(applied, privacy: .public)
            """)
        if let origin = AXBridge.point(element, kAXPositionAttribute as String),
           let size = AXBridge.size(element, kAXSizeAttribute as String) {
            state.setFrame(CGRect(origin: origin, size: size), forWindowID: entry.windowID)
        }
        bringForward(entry)
    }

    /// The display the user is looking at: the screen the pointer is on, which is
    /// also where the overlay was opened. Mapped through Quartz bounds so it is the
    /// same `DisplayInfo` tiling already speaks.
    private func lookingAtDisplay() -> DisplayInfo? {
        let point = NSEvent.mouseLocation
        let screen = Self.screen(containing: point) ?? panel?.screen
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        return state.displayLayout.display(matchingQuartzBounds: bounds)
    }

    /// After a placement, put the window in front. Resize without a raise is what
    /// left Chrome tiled behind Finder.
    private func bringForward(_ entry: WindowEntry) {
        if entry.isWindow {
            mruTracker.recordActivation(windowID: entry.windowID)
        }
        activation.bringForward(entry, canUseAccessibility: permissions.accessibilityGranted)
    }

    private func cardIndex(atScreenPoint point: CGPoint, panel: OverlayPanel) -> Int? {
        let frame = panel.frame
        guard frame.contains(point) else { return nil }
        let pointInPanel = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return state.layout.cardIndex(
            atPanelPoint: pointInPanel,
            scrollOffset: state.scrollOffset,
            // Pass the scale the card is actually drawn at, so the enlarged edges of
            // the selected card are clickable rather than a dead border.
            selectedScale: state.selectedScale
        )
    }

    private func onSelectionChanged() {
        let scale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        Task { [thumbnails] in
            // Requirement 9.8: the previous card's stream stops before a new one
            // starts. `startLiveStream` enforces the single-stream invariant, but
            // stopping here keeps the gap short when the new card is minimized.
            await thumbnails.stopLiveStream()
        }
        refreshSelectedPreview(backingScale: scale)
    }

    // MARK: - Click handling

    private enum ClickSource: String {
        case eventTap = "HID event-tap"
        case local
        case global
    }

    /// Handle every left click observed while the overlay is visible.
    ///
    /// A nonactivating panel normally receives its own mouse events, but AppKit can
    /// route a first click to the application underneath. Local and global event
    /// monitors are mutually exclusive for a given destination, so both must use the
    /// same decision path. Most importantly, a global click inside the panel is a
    /// fallback card click — not something to ignore.
    ///
    /// - Returns: `true` when a local monitor should consume the event. Global monitors
    ///   cannot consume events, so their caller ignores this result.
    @discardableResult
    private func handleLeftMouseDown(at point: CGPoint, source: ClickSource) -> Bool {
        guard state.isVisible, let panel else { return false }

        // A context menu is tracking, and choosing one of its items is itself a primary click. Left
        // to the normal path that click either dismisses the overlay or commits a card, both of which
        // happen before the menu's own action runs.
        // Not consumed — reported as unhandled so the click continues on to the menu. Consuming it
        // here was the other half of the menu never seeing its own selection.
        guard !isShowingContextMenu else {
            Log.overlay.info("primary click left to the tracking context menu")
            return false
        }

        let isInsidePanel = panel.frame.contains(point)
        guard isInsidePanel else {
            // Requirement 8.2: a click outside closes the overlay without switching,
            // and is left unconsumed so it still does whatever the user aimed it at.
            dismiss(activating: nil)
            return false
        }

        let pointInPanel = CGPoint(
            x: point.x - panel.frame.minX,
            y: point.y - panel.frame.minY
        )

        switch state.layout.target(
            atPanelPoint: pointInPanel,
            scrollOffset: state.scrollOffset,
            selectedScale: state.selectedScale
        ) {
        case .close(let index):
            // No button is drawn for a window that cannot be closed, so a click in
            // that corner means the card, not the affordance.
            guard state.entries.indices.contains(index),
                  state.canClose(state.entries[index]) else {
                state.setSelection(index)
                commitSelection()
                return true
            }
            Log.overlay.info(
                "close clicked on card \(index) via \(source.rawValue, privacy: .public) monitor"
            )
            closeWindow(at: index)
            return true

        case .card(let index):
            Log.overlay.info(
                "card \(index) clicked via \(source.rawValue, privacy: .public) monitor"
            )
            state.setSelection(index)
            commitSelection()
            return true

        case .shortcutSlot(let slot):
            pressShortcutSlot(slot)
            return true

        case .confirmSelection:
            // The list and radial styles preview the selected window at size. A click
            // there means "this one", not "never mind".
            Log.overlay.info(
                "preview clicked via \(source.rawValue, privacy: .public) monitor"
            )
            commitSelection()
            return true

        case .background:
            // Consumed so a click on empty panel background cannot fall through to the
            // application underneath.
            dismiss(activating: nil)
            return true
        }
    }

    // MARK: - Pinned shortcut slots

    private func shortcutSlot(atScreenPoint point: CGPoint, panel: OverlayPanel) -> Int? {
        state.layout.shortcutSlot(
            atPanelPoint: CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        )
    }

    /// The empty slot asks what to pin. A pin waits for the release: on itself it runs, on
    /// another slot it moves there. The 60 Hz hover sampler watches for the release, because
    /// the overlay tap never sees mouse-up.
    private func pressShortcutSlot(_ slot: Int) {
        if state.pinnedShortcut(inSlot: slot) == nil {
            showSlotMenu(slot, at: NSEvent.mouseLocation)
        } else {
            state.draggingSlot = slot
        }
    }

    private func trackSlotDrag(from slot: Int, at point: CGPoint, panel: OverlayPanel) {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        state.draggingSlot = nil
        guard let shortcut = state.pinnedShortcut(inSlot: slot) else { return }
        let target = shortcutSlot(atScreenPoint: point, panel: panel)
        if let target, target != slot {
            // A move, not a swap: dropping on the empty slot sends the pin to the end.
            state.pinnedShortcuts.remove(at: slot)
            state.pinnedShortcuts.insert(shortcut, at: min(target, state.pinnedShortcuts.count))
            PinnedShortcut.save(state.pinnedShortcuts)
        } else if target == slot {
            Log.overlay.info("running pinned shortcut \(shortcut.title, privacy: .public)")
            dismiss(activating: nil)
            shortcut.perform()
        }
    }

    /// Both the empty-slot click and the right-click land here; the same tracking flags the
    /// card menu uses keep the tap from swallowing the click that picks an item.
    private func showSlotMenu(_ slot: Int, at point: CGPoint) {
        if !state.isPersistent {
            presentationMode = .toggle
            state.isPersistent = true
            activateAsSoonAsReady = false
        }
        let menu = NSMenu()
        var actions: [MenuAction] = []
        func add(_ title: String, _ run: @escaping @MainActor () -> Void) {
            let action = MenuAction(run)
            actions.append(action)
            menu.addItem(withTitle: title, action: #selector(MenuAction.fire), keyEquivalent: "").target = action
        }
        let pinned = state.pinnedShortcut(inSlot: slot)
        if let pinned {
            add("Open \(pinned.title)") {
                self.dismiss(activating: nil)
                pinned.perform()
            }
            add("Remove") {
                self.state.pinnedShortcuts.remove(at: slot)
                PinnedShortcut.save(self.state.pinnedShortcuts)
            }
            menu.addItem(.separator())
        }
        let verb = pinned == nil ? "Pin" : "Replace with"
        add("\(verb) Link…") { self.assignSlot(slot, using: self.askForLink) }
        add("\(verb) App…") { self.assignSlot(slot, using: self.askForApp) }
        add("\(verb) Keyboard Shortcut…") { self.assignSlot(slot, using: self.askForKeys) }
        // Five pins fill the first turn and hide the plus. This is how a sixth one starts —
        // the inner turn only appears once it has something to show.
        if pinned != nil,
           state.pinnedShortcuts.count >= PinnedShortcut.firstLayerCount,
           state.pinnedShortcuts.count < PinnedShortcut.slotCount {
            menu.addItem(.separator())
            let next = state.pinnedShortcuts.count
            add("Add Link…") { self.assignSlot(next, using: self.askForLink) }
            add("Add App…") { self.assignSlot(next, using: self.askForApp) }
            add("Add Keyboard Shortcut…") { self.assignSlot(next, using: self.askForKeys) }
        }
        isShowingContextMenu = true
        triggerMonitor.contextMenuIsTracking = true
        openContextMenu = menu
        defer {
            isShowingContextMenu = false
            triggerMonitor.contextMenuIsTracking = false
            if openContextMenu === menu { openContextMenu = nil }
        }
        menu.popUp(positioning: nil, at: point, in: nil)
        withExtendedLifetime(actions) {}
    }

    /// The overlay comes down first: its panel cannot take key focus, and its tap would treat
    /// a click on the dialog as a click outside.
    private func assignSlot(_ slot: Int, using ask: @escaping @MainActor () -> PinnedShortcut?) {
        dismiss(activating: nil)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            guard let shortcut = ask() else { return }
            if state.pinnedShortcuts.indices.contains(slot) {
                state.pinnedShortcuts[slot] = shortcut
            } else if state.pinnedShortcuts.count < PinnedShortcut.slotCount {
                state.pinnedShortcuts.append(shortcut)
            }
            PinnedShortcut.save(state.pinnedShortcuts)
        }
    }

    private func askForLink() -> PinnedShortcut? {
        let field = PinLinkField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        guard runPinDialog("Pin a link", "Opens in your default browser.", accessory: field) else { return nil }
        var text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text).flatMap { $0.host == nil ? nil : .link($0) }
    }

    private func askForApp() -> PinnedShortcut? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Pin"
        return panel.runModal() == .OK ? panel.url.map(PinnedShortcut.app) : nil
    }

    private func askForKeys() -> PinnedShortcut? {
        let field = ShortcutCaptureField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let hint = "Press the keys now. They are sent to the front window when you click the slot."
        guard runPinDialog("Pin a keyboard shortcut", hint, accessory: field) else { return nil }
        return field.captured.map(PinnedShortcut.keys)
    }

    private func runPinDialog(_ title: String, _ hint: String, accessory: NSView) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = hint
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Pin")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = accessory
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func refreshSlotIcons() {
        for case .link(let url) in state.pinnedShortcuts where state.slotIcons[url] == nil {
            Task { [weak self] in
                guard let image = await self?.browserFavicons.favicon(for: url.absoluteString) else { return }
                self?.state.slotIcons[url] = NSImage(cgImage: image, size: .zero)
            }
        }
    }

    /// Close the window behind a card and leave the overlay open.
    ///
    /// Staying open is the point: closing windows is a housekeeping task done in runs,
    /// and an overlay that dismissed after each one would mean re-triggering the
    /// switcher for every window.
    private func closeWindow(at index: Int) {
        guard state.entries.indices.contains(index) else { return }
        let entry = state.entries[index]

        do {
            try activation.close(entry, canUseAccessibility: permissions.accessibilityGranted)
        } catch ActivationService.Failure.windowGone {
            // Already gone; dropping the card is still the right outcome.
            Log.activation.debug("window was already closed; removing its card")
        } catch {
            Log.activation.info("""
                could not close \(entry.applicationName, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return
        }

        invalidateBrowserInspections()
        knownIncognitoWindowIDs.remove(entry.windowID)
        incognitoResolvedWindowIDs.remove(entry.windowID)
        // The id can be handed to a different window later, so the icon verified for this one
        // must not outlive it.
        forgetBrowserIcon(for: entry.windowID)
        mruTracker.forget(windowID: entry.windowID)
        Task { [thumbnails] in
            await thumbnails.stopLiveStream()
        }
        state.remove(windowID: entry.windowID)

        guard !state.entries.isEmpty else {
            // Nothing left to switch to, so there is nothing for the overlay to do.
            Log.overlay.info("last window closed; dismissing")
            dismiss(activating: nil)
            return
        }

        // The card under the cursor has changed, so re-resolve hover and refresh the
        // preview for whatever is now selected. The cards moved rather than the pointer, so any
        // hold is released: what is under the cursor now is genuinely different.
        hoveredIndex = nil
        hoverHoldPoint = nil
        resizePanelForCurrentLayout()
        sampleHover()
        onSelectionChanged()
    }

    /// Re-fit the panel after the card count changes.
    ///
    /// Every style sizes itself from the number of cards, so a panel left at its old
    /// size would leave a gap where the closed card was — or, for the strip, keep a
    /// clickable region with nothing in it.
    private func resizePanelForCurrentLayout() {
        guard let panel, state.isVisible else { return }
        let size = state.layout.panelSize
        guard size != panel.frame.size else { return }

        let screen = Self.screen(containing: NSEvent.mouseLocation)
        let visibleFrame = screen?.visibleFrame ?? panel.frame
        let origin = OverlayPlacement.origin(
            panelSize: size,
            // Keep the panel where it is rather than letting it jump to the cursor.
            cursor: CGPoint(x: panel.frame.midX, y: panel.frame.midY),
            visibleFrame: visibleFrame,
            anchor: .cursor
        )
        panel.present(
            at: origin,
            size: size,
            afterLayout: true,
            castsShadow: state.layoutStyle.drawsBackdrop
        )
    }

    private func installClickMonitors() {
        removeClickMonitors()

        // Clicks delivered to VortexFlow, including the normal card-click path.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? NSEvent.mouseLocation
            return self.handleLeftMouseDown(at: point, source: .local) ? nil : event
        }

        // Clicks delivered to another process. A nonactivating panel can occasionally
        // let its first click reach the app beneath it, so an inside-panel click must be
        // hit-tested and committed here too. Previously this path returned early for
        // the entire panel frame, which is what left the drawer stuck on screen.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            _ = MainActor.assumeIsolated {
                self?.handleLeftMouseDown(at: NSEvent.mouseLocation, source: .global)
            }
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    // MARK: - Helpers

    /// A rectangle for the log: `x,y w×h`, whole points.
    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    /// The screen the pointer is on, by the pointer's own edge rules.
    ///
    /// Routed through `OverlayPlacement` rather than `frame.contains`, which misses a pointer
    /// in the menu bar and used to send the overlay to the main display instead.
    private static func screen(containing point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = OverlayPlacement.displayIndexContaining(
            cursor: point,
            frames: screens.map(\.frame)
        ) else {
            return NSScreen.main
        }
        return screens[index]
    }

    /// The keyboard shortcut goes through exactly the same path as the mouse button.
    ///
    /// This is deliberate rather than incidental. A button a mouse holds inside its own
    /// firmware cannot reach an event tap at all — not even when it is set to "Do
    /// Nothing", which swallows the press rather than passing it on — so the only way to
    /// use such a button is to assign it to a keyboard shortcut. Routing the shortcut
    /// through the same press/release logic means it then behaves identically: tap to
    /// keep the strip open, hold and release to switch.
    private func handleHotKeyPressed() {
        handlePress(from: .keyboardShortcut)
    }

    /// One entry point for both triggers, differing only where they should.
    private func handlePress(from source: TriggerSource) {
        if isShowingContextMenu {
            openContextMenu?.cancelTracking()
        }
        if source == .keyboardShortcut {
            hotKeyMonitor.noteArrival()
        }

        let onScreen = OverlayPresence.isOnScreen(
            stateVisible: state.isVisible,
            panelVisible: panel?.isVisible ?? false,
            frame: panel?.frame ?? .zero,
            isRevealed: state.isRevealed
        )

        // A leftover `isVisible` with nothing on screen used to make the shortcut
        // *close* an overlay the user could not see. Repair, then open.
        if state.isVisible && !onScreen {
            Log.overlay.info("overlay flag was leftover; repairing and opening")
            dismiss(activating: nil)
            suppressTriggerUntil = nil
            beginPresentation(mode: .hold)
            return
        }

        switch TriggerResponse.forPress(
            from: source,
            overlayVisible: onScreen,
            mode: presentationMode
        ) {
        case .open:
            if TriggerOpenGate.shouldIgnoreDuplicate(
                source: source,
                recentlyDismissed: isTriggerSuppressed
            ) {
                Log.trigger.debug("ignoring trigger press immediately after a dismissal")
                return
            }
            // Requirement 5.5.
            beginPresentation(mode: .hold)

        case .commitSelection:
            commitSelection()

        case .dismissWithoutSwitching:
            // Requirement 6.2.
            Log.overlay.info("shortcut pressed again; closing the overlay without switching")
            dismiss(activating: nil)

        case .ignore:
            // The last silent branch, and the one that made "it only opens once" undiagnosable: a
            // press that is neither an open, a commit nor a dismissal left no trace at all, so a
            // stuck state was indistinguishable from a trigger that never arrived.
            Log.trigger.info("""
                trigger press ignored: overlay visible=\(self.state.isVisible, privacy: .public), \
                onScreen=\(onScreen, privacy: .public), \
                mode=\(String(describing: self.presentationMode), privacy: .public), \
                presenting=\(self.isPresenting, privacy: .public), \
                menuTracking=\(self.isShowingContextMenu, privacy: .public)
                """)
        }
    }

    private func handleHotKeyReleased(heldFor duration: TimeInterval) {
        triggerButtonReleased(heldFor: duration)
    }
}

// MARK: - TriggerMonitorDelegate

extension SwitcherController: TriggerMonitorDelegate {

    func triggerButtonPressed() {
        handlePress(from: .button)
    }

    func triggerButtonReleased(heldFor duration: TimeInterval) {
        // A release with nothing on screen has nothing to act on. It arrives routinely — the
        // shortcut's own release lands just after a press closed the overlay — and without this it
        // would leave the tap branch below setting flags for a presentation that is already gone.
        guard state.isVisible || isPresenting else { return }

        // Requirement 5.10 and 8.3, now filtered through the activation mode.
        guard presentationMode == .hold else { return }

        let shouldCommit = settings.activationMode.commitsOnRelease(heldFor: duration)

        guard shouldCommit else {
            // A tap, not a hold. Leave the strip up so the user can read it and click
            // or scroll at their own pace, and remember that this presentation is now
            // a toggle so a later release does not close it.
            presentationMode = .toggle
            activateAsSoonAsReady = false
            state.isPersistent = true
            Log.overlay.debug("tap detected (\(duration, format: .fixed(precision: 3)) s); keeping the strip open")
            return
        }

        if isPresenting {
            // Released faster than enumeration; honour it once the list lands.
            activateAsSoonAsReady = true
            return
        }
        guard state.isVisible else { return }
        commitSelection()
    }

    func leftMousePressed(atScreenPoint point: CGPoint) {
        handleLeftMouseDown(at: point, source: .eventTap)
    }

    func buttonCaptured(number: Int) {
        guard let captured = TriggerButton(number: number) else {
            // Left and right buttons are refused: consuming either would break
            // ordinary clicking everywhere.
            Log.trigger.info("ignoring captured button \(number); only buttons 2 and above can be used")
            onButtonCaptured?(nil)
            onButtonCaptured = nil
            return
        }
        Log.trigger.info("captured trigger button \(number)")
        settings.triggerButton = captured
        applySettingsChange()
        onButtonCaptured?(captured)
        onButtonCaptured = nil
    }

    func scrollReceived(delta: Double) {
        guard state.isVisible, !state.entries.isEmpty else { return }
        // Requirement 4.1, 4.2.
        let steps = scrollAccumulator.consume(delta: delta)
        guard steps != 0 else { return }

        // Requirement 4.3–4.6: wrap at both ends.
        let next = SelectionMath.advance(
            current: state.selectedIndex,
            by: steps,
            count: state.entries.count
        )
        guard next != state.selectedIndex else { return }
        state.setSelection(next)
        // Scrolling takes precedence over a stale hover highlight.
        hoveredIndex = nil
        onSelectionChanged()
    }

    /// Move the selection with the arrow keys.
    ///
    /// Shares everything below the step itself with scrolling — the same wrapping, the same
    /// hover override, the same follow-up work — because they are the same gesture arriving from
    /// a different device, and two paths would drift.
    func arrowPressed(_ direction: ArrowDirection) {
        guard state.isVisible, !state.entries.isEmpty else { return }

        // The arrangement decides what the key means; a grid crosses a row where the others move
        // one card.
        let step = state.layout.selectionStep(for: direction)
        guard step != 0 else { return }

        let next = SelectionMath.advance(
            current: state.selectedIndex,
            by: step,
            count: state.entries.count
        )
        guard next != state.selectedIndex else { return }

        state.setSelection(next)
        // The keyboard has taken over; a highlight left under a stationary pointer would now be
        // claiming a selection that has moved on.
        hoveredIndex = nil
        holdHoverUntilPointerMoves()
        onSelectionChanged()
    }

    /// Stop the pointer's current position from re-choosing the selection until it is moved.
    ///
    /// Called from wherever something that is not the pointer decides the selection. See
    /// `hoverHoldPoint`.
    private func holdHoverUntilPointerMoves() {
        hoverHoldPoint = NSEvent.mouseLocation
    }

    /// The shortcut pressed again while the overlay is up.
    ///
    /// Routed into the same press handling as the global hotkey rather than into `escapePressed()`.
    /// The overlay's own event tap consumes the keystroke — it has to, or a space would be typed as
    /// well — which means the Carbon hotkey never sees it, so this has to reproduce the hotkey's
    /// behaviour exactly rather than approximate it with a dismissal.
    func keyboardShortcutPressed() {
        handlePress(from: .keyboardShortcut)
    }

    func escapePressed() {
        // Requirement 8.1.
        guard state.isVisible else { return }

        // With a search active, Escape backs out of the search first. Closing the whole
        // overlay on a mistyped letter would be a harsh way to learn that.
        if state.clearSearch() {
            pendingTabSearchWindowID = nil
            pendingSearchConfirmation = nil
            publishSearchActive()
            Log.overlay.debug("search cleared")
            afterSearchChanged()
            return
        }
        dismiss(activating: nil)
    }

    func searchCharactersTyped(_ characters: String) {
        guard state.isVisible else { return }
        pendingSearchConfirmation = nil
        let changed = state.appendToSearch(characters)
        publishSearchActive()
        // Shape only, never content: the query is the user's own typing. Enough to tell a stray
        // space that the switcher inserted from one the user meant, which is the only way to
        // separate "the caret is drawn too far right" from "a space really is in there".
        if characters.allSatisfy(\.isWhitespace) {
            Log.overlay.info("""
                whitespace typed into search; query is now \(self.state.searchQuery.count)                 characters and ends with whitespace: \
                \(self.state.searchQuery.last?.isWhitespace == true)
                """)
        }
        loadBrowserTabsIfNeeded()
        guard changed else { return }
        afterSearchChanged()
    }

    /// Restrict the overlay to this window's tabs.
    ///
    /// Pairing to the browser's scripting id can lag the right-click, and hiding the
    /// item until it arrived is what made "Search through Tabs" disappear from Chrome
    /// cards. Choosing the item always starts the fetch; if the pairing is not in yet,
    /// it is applied when inspection lands.
    private func searchTabs(of entry: WindowEntry) {
        pendingTabSearchWindowID = entry.windowID

        // Chrome's AppleScript `windows` collection is currently empty on this OS
        // (osascript reports 0 while System Events sees the real windows). The tab
        // strip in the accessibility tree still names every tab, keyed by CGWindowID,
        // which is already on the card.
        if let browser = BrowserTab.Browser.allCases.first(
            where: { $0.bundleIdentifier == entry.bundleIdentifier }
        ), browser != .terminal {
            var axTabs: [BrowserTab] = []
            if let element = entry.axElement {
                axTabs = BrowserTabAlertService.tabs(
                    inWindow: element,
                    windowID: entry.windowID,
                    browser: browser,
                    processIdentifier: entry.processID
                )
            }
            if axTabs.isEmpty {
                axTabs = BrowserTabAlertService.tabs(inProcess: entry.processID, browser: browser)
                    .filter { $0.windowIdentifier == Int(entry.windowID) }
            }
            if !axTabs.isEmpty {
                let application = NSRunningApplication(processIdentifier: entry.processID)
                pendingTabSearchWindowID = nil
                state.setTabs(axTabs.map {
                    WindowEntry.tabEntry(
                        $0,
                        application: application,
                        windowElement: entry.axElement
                    )
                })
                state.setTabScope(Int(entry.windowID))
                afterSearchChanged()
                Log.overlay.info("""
                    search through tabs via accessibility: \
                    \(axTabs.count, privacy: .public) tabs, \
                    window \(entry.windowID, privacy: .public), \
                    visible \(self.state.entries.count, privacy: .public)
                    """)
                // The strip has titles, not URLs. Scripting still knows addresses
                // across Spaces; filling those in is what makes hosts and favicons
                // appear on the wedges instead of a ring of identical Chrome icons.
                enrichTabAddressesFromScripting(window: entry, presentationID: state.presentationID)
                return
            }
            Log.overlay.info("""
                search through tabs found no accessibility tabs in window \
                \(entry.windowID, privacy: .public); trying scripting
                """)
        }

        if let identifier = scriptedWindowIdentifiers[entry.windowID] {
            pendingTabSearchWindowID = nil
            state.setTabScope(identifier)
        } else if let identifier = state.windowIdentifierForTabScope(matching: entry) {
            scriptedWindowIdentifiers[entry.windowID] = identifier
            pendingTabSearchWindowID = nil
            state.setTabScope(identifier)
        } else {
            state.beginAwaitingTabScope()
        }
        afterSearchChanged()
        Log.overlay.info("""
            search through tabs window \(entry.windowID, privacy: .public) \
            paired id \(self.scriptedWindowIdentifiers[entry.windowID].map(String.init) ?? "none", privacy: .public) \
            awaiting \(self.state.isAwaitingTabScope, privacy: .public)
            """)
        loadBrowserTabsIfNeeded()
        resolvePendingTabSearch()
    }

    /// Fill URLs onto Accessibility-listed tabs once scripting answers.
    ///
    /// Chrome's tab strip is what we show, because it still works for a window on
    /// another Space. Favicons and domain labels need the address, which the strip
    /// does not have — `AXURL` comes back empty. The scripting dictionary does, and
    /// it is not Space-bound.
    private func enrichTabAddressesFromScripting(window entry: WindowEntry, presentationID: Int) {
        Task { [weak self, browserTabs] in
            let scripted = await browserTabs.tabs()
            await MainActor.run {
                guard let self,
                      self.state.isVisible,
                      self.state.presentationID == presentationID
                else { return }
                let changed = self.state.enrichTabAddresses(scripted, matching: entry)
                Log.overlay.info("""
                    tab addresses merged: \
                    \(scripted.count, privacy: .public) scripted, \
                    visible \(self.state.entries.count, privacy: .public), \
                    with host \(self.state.entries.filter { $0.tab.map { !$0.host.isEmpty } ?? false }.count, privacy: .public)
                    """)
                if changed {
                    self.afterSearchChanged()
                } else {
                    self.refreshTabIcons()
                }
            }
        }
    }

    private func applyPendingTabSearch() {
        guard let windowID = pendingTabSearchWindowID,
              let identifier = scriptedWindowIdentifiers[windowID]
        else { return }
        pendingTabSearchWindowID = nil
        state.setTabScope(identifier)
        loadBrowserTabsIfNeeded()
        afterSearchChanged()
    }

    /// Finish a pending "Search through Tabs" from pairing or from the tab list itself.
    private func resolvePendingTabSearch() {
        guard let windowID = pendingTabSearchWindowID else { return }
        if scriptedWindowIdentifiers[windowID] != nil {
            applyPendingTabSearch()
            return
        }
        let entry = state.allWindowEntries.first { $0.windowID == windowID }
        if let entry, let identifier = state.windowIdentifierForTabScope(matching: entry) {
            scriptedWindowIdentifiers[windowID] = identifier
            applyPendingTabSearch()
            return
        }
        guard state.hasLoadedTabs else { return }
        pendingTabSearchWindowID = nil
        state.finishTabScopeWithoutTabs(reason: "Couldn't find tabs in this window")
        afterSearchChanged()
        Log.registry.info("tab search could not pair window \(windowID, privacy: .public)")
    }

    /// Fetch browser tabs once per presentation, the first time the user types.
    ///
    /// Deliberately not at presentation time: listing tabs costs an Apple Event round trip
    /// per browser window, around 0.3 s in total, against a 150 ms budget for showing the
    /// overlay (Requirement 14.1). Typing is the moment the user is looking for something
    /// by name, and is the only moment tabs are worth that cost.
    /// Relinquish ownership of an AppleScript request without waiting for its synchronous work
    /// to return. The request-id check drops its eventual callback, and a reopened presentation
    /// can start its own 750 ms deadline immediately even if the browser actor is still busy.
    private func invalidateBrowserTabLoad() {
        browserTabRequestID &+= 1
        isLoadingBrowserTabs = false
    }

    private func loadBrowserTabsIfNeeded() {
        guard !state.hasLoadedTabs, !isLoadingBrowserTabs else { return }
        isLoadingBrowserTabs = true
        browserTabRequestID &+= 1

        let requestID = browserTabRequestID
        let presentationID = state.presentationID
        let timeoutNanoseconds = Self.browserTabSearchTimeoutNanoseconds

        Task { [weak self, browserTabs] in
            let tabs = await browserTabs.tabs()
            // Keyed by process, not bundle identifier. Two instances of one browser are two
            // processes sharing an identifier, and a tab has to take its icon and its pid from
            // the one it actually belongs to — that is what makes activation reach it.
            let applications = await MainActor.run {
                Dictionary(
                    NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            let entries = tabs.map { tab in
                WindowEntry.tabEntry(tab, application: applications[tab.processIdentifier])
            }

            await MainActor.run {
                self?.finishBrowserTabLoad(
                    entries,
                    requestID: requestID,
                    presentationID: presentationID
                )
            }
        }

        // AppleScript is synchronous inside the browser service and cannot be cancelled while
        // an Automation prompt or an unresponsive browser is holding it. Bound how long it may
        // gate local application results; a late answer is deliberately ignored for this query
        // so the selected app cannot suddenly be replaced under the user.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            await MainActor.run {
                self?.timeOutBrowserTabLoad(
                    requestID: requestID,
                    presentationID: presentationID
                )
            }
        }
    }

    private func finishBrowserTabLoad(
        _ entries: [WindowEntry],
        requestID: UInt64,
        presentationID: Int
    ) {
        guard requestID == browserTabRequestID else { return }
        isLoadingBrowserTabs = false

        guard state.isVisible,
              state.presentationID == presentationID,
              !state.hasLoadedTabs else {
            // If this result belonged to a dismissed presentation, free the slot and begin the
            // currently visible search's own request rather than injecting stale tabs into it.
            if state.isVisible, state.isSearching, state.presentationID != presentationID {
                loadBrowserTabsIfNeeded()
            }
            return
        }

        Log.registry.info("found \(entries.count) browser tabs to search")
        settleBrowserTabs(entries)
        Log.overlay.info("""
            tab search settled: \(entries.count, privacy: .public) tabs, \
            scope \(self.state.tabScope.map(String.init) ?? "none", privacy: .public), \
            visible \(self.state.entries.count, privacy: .public)
            """)
    }

    private func timeOutBrowserTabLoad(requestID: UInt64, presentationID: Int) {
        guard requestID == browserTabRequestID else { return }

        guard state.isVisible,
              state.presentationID == presentationID,
              !state.hasLoadedTabs else {
            isLoadingBrowserTabs = false
            if state.isVisible, state.isSearching, state.presentationID != presentationID {
                loadBrowserTabsIfNeeded()
            }
            return
        }

        // A tab-scope fetch has to wait for the real list. Clearing `isLoadingBrowserTabs`
        // here was the hang: the next pairing callback started a *second* fetch, the first
        // reply was dropped as stale, and the overlay stayed on "Looking for tabs…".
        if state.tabScope != nil || state.isAwaitingTabScope { return }

        isLoadingBrowserTabs = false
        Log.registry.info("browser tab search exceeded 750 ms; continuing with applications")
        settleBrowserTabs([])
    }

    private func settleBrowserTabs(_ entries: [WindowEntry]) {
        let changed = state.setTabs(entries)
        resolvePendingTabSearch()
        if changed || state.tabScope != nil {
            afterSearchChanged()
        }
        refreshTabMediaAlerts(for: entries)
        resolvePendingSearchConfirmationIfReady()
    }

    /// Ask each browser's tab strip which of its tabs are playing or recording.
    ///
    /// Hooked to tabs arriving rather than to presentation, because tabs do not exist until the user
    /// types — they are fetched over Apple Events on the first keystroke — so there is nothing to
    /// mark at the moment the panel appears.
    ///
    /// Off the main thread for the same reason the window-level query is: this is an accessibility
    /// walk into another application, which is an IPC round trip that gets slow exactly when the
    /// machine is busy. `AXBridge`'s messaging timeout bounds a stall; it does not prevent one.
    private func refreshTabMediaAlerts(for entries: [WindowEntry]) {
        let browsers = Set(entries.filter(\.isTab).map(\.processID).filter { $0 > 0 })
        guard !browsers.isEmpty else {
            state.tabMediaAlerts = [:]
            return
        }

        let presentationID = state.presentationID
        // Only the pids cross to the work queue. The entries stay here: a `WindowEntry` holds a live
        // `AXUIElement`, and the pairing is string comparison over a handful of readings, so there is
        // nothing to gain by sending it and a thread-safety question to answer if it went.
        workQueue.async { [weak self] in
            let readings = BrowserTabAlertService.survey(browserProcesses: browsers).readings
            DispatchQueue.main.async {
                guard let self, self.state.presentationID == presentationID else { return }
                let alerts = TabMediaAlert.alerts(forTabsIn: entries, readings: readings)
                if !readings.isEmpty {
                    Log.overlay.info(
                        """
                        tab media: \(readings.count, privacy: .public) alerting tabs reported, \
                        \(alerts.count, privacy: .public) matched to results
                        """
                    )
                }
                guard self.state.tabMediaAlerts != alerts else { return }
                self.state.tabMediaAlerts = alerts
            }
        }
    }

    func searchBackspacePressed() {
        guard state.isVisible else { return }
        pendingSearchConfirmation = nil
        let changed = state.backspaceSearch()
        publishSearchActive()
        guard changed else { return }
        afterSearchChanged()
    }

    /// Command with a delete key: the whole query goes.
    ///
    /// Deliberately not routed into `escapePressed()`, which clears the query too. Escape falls
    /// through to dismissing the overlay when there is nothing to clear, and a delete key must
    /// never close the switcher — a user wiping a query they mistyped would lose the overlay along
    /// with it.
    func searchClearPressed() {
        guard state.isVisible else { return }
        pendingSearchConfirmation = nil
        let changed = state.clearSearch()
        publishSearchActive()
        guard changed else { return }
        afterSearchChanged()
    }

    /// Command-A: select the whole query so the next edit replaces it.
    ///
    /// No re-filtering and no re-fitting, because selecting text changes nothing about what
    /// matched — only the pill's own appearance changes, and that follows from the published flag.
    func searchSelectAllPressed() {
        guard state.isVisible else { return }
        state.selectAllSearch()
    }

    /// Tell the tap whether a query is active, since that decides what Command-A means.
    ///
    /// Called from every path that can change the answer rather than from `afterSearchChanged()`,
    /// which is skipped whenever the visible list happens not to have changed — and the query can
    /// change without the list changing, most obviously when it goes from one space to none.
    private func publishSearchActive() {
        triggerMonitor.isSearchActive = state.isSearching
    }

    /// Re-fit and re-capture after the visible list changes.
    private func afterSearchChanged() {
        hoveredIndex = nil
        // Typing put the selection on the best match. A pointer that happens to be resting over a
        // card would otherwise take it straight back, so the search would filter the list and then
        // select something other than what it had ranked first.
        holdHoverUntilPointerMoves()
        resizePanelForCurrentLayout()
        refreshTabIcons()

        // Filtering can bring windows into view whose thumbnails were never captured,
        // because capture is scoped to what was on screen. Tabs are skipped: they have no
        // window to capture, and a browser screenshot would show whichever tab is currently
        // frontmost rather than the one being offered.
        refreshPromptIcons()

        let capturable = state.entries.filter(\.isWindow)
        guard !capturable.isEmpty else { return }
        let scale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        startCaptures(for: capturable, backingScale: scale)
    }

    /// Resolve site icons for the tab results currently on screen.
    ///
    /// Bounded to what is visible, which matters here more than it does for windows: a search can
    /// match dozens of tabs, and a browser with forty of them would otherwise fan out forty
    /// requests for a list the user is about to narrow further with the next keystroke. The service
    /// deduplicates by origin underneath, so ten tabs on one site cost one request.
    /// Resolve the assistants' own logos for the prompt results on screen.
    ///
    /// The same service the tab results use, for the same reason: a brand mark cannot be an SF
    /// Symbol, and shipping three logos as assets would mean carrying someone else's trademark in
    /// the bundle and re-shipping the app whenever one of them is restyled. Their own favicon is
    /// the version they are currently using, by definition.
    ///
    /// What goes on the wire is `logoSourceURL` — the provider's front page and nothing else. The
    /// prompt URL is never fetched, so what the user typed does not leave the machine until they
    /// actually pick one of these results. The service deduplicates by origin and caches, so three
    /// providers cost three requests once rather than three per keystroke.
    private func refreshPromptIcons() {
        guard state.isVisible else { return }
        let presentationID = state.presentationID

        let pending = state.entries.filter { entry in
            entry.webSearch?.logoSourceURL != nil && !state.hasSiteIcon(for: entry)
        }

        for entry in pending {
            guard let source = entry.webSearch?.logoSourceURL else { continue }
            let entryID = entry.id

            Task { [weak self, browserFavicons] in
                guard let self,
                      let logo = await browserFavicons.favicon(for: source)
                else { return }

                let image = NSImage(
                    cgImage: logo,
                    size: NSSize(width: logo.width, height: logo.height)
                )
                // Not a template: these are brand marks, and recolouring them to the palette's
                // text colour would turn three distinguishable logos into three identical
                // silhouettes — which is the whole reason they are worth fetching.
                image.isTemplate = false

                self.state.setWebResultIcon(
                    image,
                    tint: IconTint.sampled(from: image),
                    for: entryID,
                    presentationID: presentationID
                )
            }
        }
    }

    private func refreshTabIcons() {
        guard state.isVisible else { return }
        let presentationID = state.presentationID

        let pending = state.entries
            .filter { $0.isTab && !state.hasSiteIcon(for: $0) }
            .prefix(Self.maximumVisibleTabIconRequests)

        for entry in pending {
            // Fails closed: a tab whose window did not report the browser's exact `normal` mode is
            // never sent to the network, so a private tab keeps the plain browser icon.
            guard let tab = entry.tab, tab.allowsFaviconRequest else { continue }

            let entryID = entry.id
            let browserIcon = entry.applicationIcon

            Task { [weak self, browserFavicons] in
                guard let self,
                      let favicon = await browserFavicons.favicon(for: tab.url)
                else { return }

                let siteIcon = NSImage(
                    cgImage: favicon,
                    size: NSSize(width: favicon.width, height: favicon.height)
                )
                siteIcon.isTemplate = false

                // Same composition as a browser window's: the browser in front, the site behind
                // it, so a tab result reads as "a page, in this browser" at a glance.
                let composed = browserIcon.map {
                    BrowserWindowIcon.layered(siteIcon: siteIcon, browserIcon: $0)
                } ?? siteIcon

                self.state.setTabIcon(
                    composed,
                    tint: IconTint.sampled(from: siteIcon),
                    for: entryID,
                    presentationID: presentationID
                )
            }
        }
    }

    func confirmPressed() {
        // Requirement 6.4. The shared commit path queues this intent if tabs or applications
        // are still resolving, then preserves Return's final web-search fallback once settled.
        guard state.isVisible else { return }
        commitSelection(intent: .returnKey)
    }

    /// Shift-Return: the first web hit for whatever was typed, not the selected wedge.
    ///
    /// Return already means "the thing under the pointer". This is the other habit: I know
    /// this is on the web, skip the results page. Queued while tabs are still resolving
    /// so a fast Shift-Return is not dropped as a miss.
    func firstWebResultPressed() {
        guard state.isVisible else { return }
        let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        if state.isResolvingSearch {
            pendingSearchConfirmation = PendingSearchConfirmation(
                presentationID: state.presentationID,
                query: state.searchQuery,
                intent: .firstWebResult
            )
            Log.overlay.debug("queued first-web-result until local search sources settle")
            return
        }
        openFirstWebResult()
    }

    private func openFirstWebResult() {
        let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let planned = WebSearch.firstResultDestination(for: query) else { return }
        openInDefaultBrowser(planned)
    }

    /// Hand a destination to whichever browser the user has set as their default.
    private func openInDefaultBrowser(_ destination: WebSearch.Destination) {
        // Deliberately not phrased as "no window matched" any more. This is reached both from the
        // empty state and from a web-search result the user picked while local matches were on
        // screen, and a log line that asserted the first would be wrong half the time.
        switch destination {
        case .firstResult:
            // Follow Lucky in-process so Chrome never sees google.com/url's redirect notice.
            let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss(activating: nil)
            Task {
                let resolved = await WebSearch.resolvedFirstResult(for: query)
                await MainActor.run {
                    guard let resolved else { return }
                    Log.overlay.info("opening the first web result for the query")
                    NSWorkspace.shared.open(resolved.url)
                }
            }
            return
        case .address:
            Log.overlay.info("opening the query as an address")
        case .search:
            Log.overlay.info("searching the web for the query")
        case .prompt(let provider, _):
            // Shape only, never the prompt itself: what the user typed is theirs, and a log is a
            // place it has no reason to end up.
            Log.overlay.info("handing the query to \(provider.rawValue, privacy: .public) as a prompt")
        }

        // Dismissed first, so the overlay is gone before the browser comes forward rather than
        // hanging over it while the page loads.
        dismiss(activating: nil)
        NSWorkspace.shared.open(destination.url)
    }

    func eventTapBecameUnstable(_ unstable: Bool) {
        // Requirement 5.13.
        permissions.setWarning(.eventTapUnstable, active: unstable)
    }
}

// MARK: - Hosting view

/// Bridges the controller's non-published hover index into SwiftUI.
///
/// Hover updates at 60 Hz. Publishing it through `OverlayState` would invalidate the
/// whole strip on every sample; instead the hosting view re-reads it on each render
/// pass that the selection change already triggered, which is the only time the
/// highlight can actually differ.
private struct OverlayHostView: View {
    @ObservedObject var state: OverlayState
    let controller: SwitcherController

    var body: some View {
        OverlayView(state: state, hoveredIndex: controller.currentHoveredIndex)
    }
}
