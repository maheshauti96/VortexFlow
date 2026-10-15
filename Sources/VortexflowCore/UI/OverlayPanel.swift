import AppKit
import SwiftUI

/// A nonactivating panel must still accept its first mouse-down. Without this override,
/// AppKit may route that click to the application beneath the overlay instead of the
/// hosted SwiftUI hierarchy.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating window the strip lives in (Requirement 13).
///
/// The configuration here is what makes a switcher overlay behave correctly, and
/// each piece is load-bearing:
///
/// - `.nonactivatingPanel` plus `canBecomeKey == false`: showing the switcher must
///   not steal focus from the app the user is in (Requirement 13.4). If the panel
///   took key focus, the "currently frontmost window" that Requirement 8's dismissal
///   paths must leave untouched would already have changed by the time the overlay
///   appeared.
/// - `level = .popUpMenu`: above ordinary windows (Requirement 13.5) without sitting
///   above system alerts.
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.canJoinAllApplications`: joins
///   other applications' full-screen Spaces and Stage Manager sets (Requirement 13.6).
/// - `hidesOnDeactivate = false`: VortexFlow is never the active app, so a panel that
///   hid on deactivation would never be visible at all.
///
/// The panel is pre-built and reused while it belongs to the active Space. A display
/// reconfiguration or detached Space membership requires a new native window; ordering
/// the old one forward cannot repair its membership.
final class OverlayPanel: NSPanel {

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications,
            .ignoresCycle, .stationary,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // Visible to screen capture, which is what people expect of anything they can see.
        // Overridden per presentation from settings; see `setIncludedInScreenshots(_:)`.
        sharingType = .readOnly
        animationBehavior = .none
        // No title bar, no traffic lights, nothing to tab into.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Leave `translatesAutoresizingMaskIntoConstraints` at its default of true.
        // Setting it to false without then adding any constraints leaves the hosting
        // view with no way to track the window: it collapses to its intrinsic size
        // and stays there, so resizing the panel per presentation would move the
        // window while the SwiftUI content stayed small and misplaced.
        let hosting = OverlayHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// Whether the panel appears in screenshots, recordings and screen shares.
    ///
    /// It used to be permanently excluded, justified as keeping the overlay out of its own
    /// thumbnails. That reasoning does not hold: `ThumbnailService` captures each window
    /// individually through `SCContentFilter(desktopIndependentWindow:)`, and a per-window
    /// capture of somebody else's window cannot contain this panel whatever its sharing type.
    /// The only real effect was that the switcher could not be screenshotted at all, which is
    /// surprising for something plainly on screen and makes it impossible to file a bug about.
    ///
    /// So it is visible by default and this exists to opt out — the reason someone would want to
    /// is a screen recording, where the overlay lists the titles of every open window.
    func setIncludedInScreenshots(_ included: Bool) {
        let desired: NSWindow.SharingType = included ? .readOnly : .none
        guard sharingType != desired else { return }
        sharingType = desired
    }

    /// Requirement 13.4: never becomes key, so the app underneath keeps focus. Key
    /// events reach the overlay through the event tap instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit can report a nonactivating panel as visible on an active Space while
    /// WindowServer excludes it. Occlusion state also lags for these panels, including
    /// ones the user can see, so use the server's own record for trigger decisions.
    var isOnScreenByWindowServer: Bool {
        guard windowNumber > 0,
              let windows = CGWindowListCopyWindowInfo(
                .optionIncludingWindow, CGWindowID(windowNumber)
              ) as? [[String: Any]],
              let window = windows.first else { return false }
        return window[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Resize to `size`, place at `origin`, and show without activating.
    ///
    /// - Parameter afterLayout: run a synchronous layout and display pass before the
    ///   panel is ordered in. SwiftUI applies state changes on a later run loop pass,
    ///   so without this the first visible frame can still be showing the previous
    ///   presentation's contents.
    /// - Parameter castsShadow: whether the window itself draws a shadow.
    ///
    ///   Only styles that draw a plate want one. With a fully transparent panel, AppKit
    ///   derives the shadow from the content's alpha mask and recomputes it whenever the
    ///   content changes — which, with a card scaling up under the cursor, means on
    ///   every animation frame. Those styles give each card its own shadow in SwiftUI
    ///   instead, which is both steadier and closer to what a floating card should look
    ///   like.
    func present(
        at origin: CGPoint,
        size: CGSize,
        afterLayout: Bool = false,
        castsShadow: Bool = true
    ) {
        setFrame(NSRect(origin: origin, size: size), display: false)

        if hasShadow != castsShadow {
            hasShadow = castsShadow
        }

        if afterLayout, let contentView {
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()
        }

        orderFrontRegardless()
        // Ordering in is what gives the window a shadow to invalidate, so this has to
        // follow it rather than sit beside the property change.
        invalidateShadow()
    }

    func dismiss() {
        orderOut(nil)
    }
}
