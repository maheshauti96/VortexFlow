import CoreGraphics
import Foundation

/// Whether the overlay is actually in front of the user.
///
/// `OverlayState.isVisible` is the flag `TriggerResponse` used to trust. A Space
/// change, a display reconfiguration, or a panel that never composited can leave
/// that flag true while nothing is on screen — and the next shortcut then closes
/// an overlay the user cannot see. AppKit's `isVisible` stays true for an ordered
/// window on another Space, so also check Space membership and WindowServer's
/// on-screen flag before interpreting the next trigger as a dismissal or selection.
enum OverlayPresence: Equatable, Sendable {

    /// The switcher is on screen and large enough to be the thing the user is looking at.
    static func isOnScreen(
        stateVisible: Bool,
        panelVisible: Bool,
        panelOnActiveSpace: Bool,
        panelOnScreen: Bool,
        frame: CGRect,
        isRevealed: Bool
    ) -> Bool {
        stateVisible
            && panelVisible
            && panelOnActiveSpace
            && panelOnScreen
            && isRevealed
            && frame.width > 1
            && frame.height > 1
    }
}

/// Whether a trigger that wants to open should be dropped as a duplicate.
///
/// The 120 ms window exists because HID and CGEvent can both report the same
/// physical mouse button. A keyboard shortcut is one event; suppressing it is
/// how a tap after a leftover dismiss looked like a dead key.
enum TriggerOpenGate: Equatable, Sendable {

    static func shouldIgnoreDuplicate(
        source: TriggerSource,
        recentlyDismissed: Bool
    ) -> Bool {
        source == .button && recentlyDismissed
    }
}
