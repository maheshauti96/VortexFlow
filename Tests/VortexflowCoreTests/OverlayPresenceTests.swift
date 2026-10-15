import CoreGraphics
import Testing
@testable import VortexflowCore

@Suite("Overlay presence")
struct OverlayPresenceTests {

    private static let visibleFrame = CGRect(x: 100, y: 100, width: 800, height: 400)

    @Test("an ordered panel on another Space makes the next trigger open")
    func anotherSpaceDoesNotSwallowTheTrigger() {
        let visible = OverlayPresence.isOnScreen(
            stateVisible: true,
            panelVisible: true,
            panelOnActiveSpace: false,
            panelOnScreen: true,
            frame: Self.visibleFrame,
            isRevealed: true
        )
        #expect(!visible)
        for source in [TriggerSource.keyboardShortcut, .button] {
            #expect(TriggerResponse.forPress(from: source, overlayVisible: visible, mode: .toggle) == .open)
        }
    }

    @Test("a panel absent from WindowServer's on-screen set makes the next trigger open")
    func windowServerDisagreementDoesNotSwallowTheTrigger() {
        let visible = OverlayPresence.isOnScreen(
            stateVisible: true,
            panelVisible: true,
            panelOnActiveSpace: true,
            panelOnScreen: false,
            frame: Self.visibleFrame,
            isRevealed: true
        )
        #expect(!visible)
        for source in [TriggerSource.keyboardShortcut, .button] {
            #expect(TriggerResponse.forPress(from: source, overlayVisible: visible, mode: .toggle) == .open)
        }
    }

    @Test("a revealed panel with a real frame is on screen")
    func revealedPanelIsOnScreen() {
        #expect(
            OverlayPresence.isOnScreen(
                stateVisible: true,
                panelVisible: true,
                panelOnActiveSpace: true,
                panelOnScreen: true,
                frame: Self.visibleFrame,
                isRevealed: true
            )
        )
    }

    @Test("a leftover visible flag with a dead panel is not on screen")
    func leftoverFlagIsNotOnScreen() {
        #expect(
            !OverlayPresence.isOnScreen(
                stateVisible: true,
                panelVisible: false,
                panelOnActiveSpace: true,
                panelOnScreen: true,
                frame: Self.visibleFrame,
                isRevealed: true
            )
        )
    }

    @Test("an unrevealed spiral is not on screen")
    func unrevealedCardsAreNotOnScreen() {
        #expect(
            !OverlayPresence.isOnScreen(
                stateVisible: true,
                panelVisible: true,
                panelOnActiveSpace: true,
                panelOnScreen: true,
                frame: Self.visibleFrame,
                isRevealed: false
            )
        )
    }

    @Test("a collapsed panel is not on screen")
    func collapsedPanelIsNotOnScreen() {
        #expect(
            !OverlayPresence.isOnScreen(
                stateVisible: true,
                panelVisible: true,
                panelOnActiveSpace: true,
                panelOnScreen: true,
                frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                isRevealed: true
            )
        )
    }

    @Test("a hidden state is not on screen")
    func hiddenStateIsNotOnScreen() {
        #expect(
            !OverlayPresence.isOnScreen(
                stateVisible: false,
                panelVisible: true,
                panelOnActiveSpace: true,
                panelOnScreen: true,
                frame: Self.visibleFrame,
                isRevealed: true
            )
        )
    }
}

@Suite("Trigger open gate")
struct TriggerOpenGateTests {

    @Test("a mouse press right after dismiss is a duplicate")
    func mouseIsSuppressedAfterDismiss() {
        #expect(
            TriggerOpenGate.shouldIgnoreDuplicate(source: .button, recentlyDismissed: true)
        )
    }

    @Test("a keyboard press is never suppressed after dismiss")
    func keyboardIsNeverSuppressed() {
        #expect(
            !TriggerOpenGate.shouldIgnoreDuplicate(
                source: .keyboardShortcut,
                recentlyDismissed: true
            )
        )
    }

    @Test("neither trigger is suppressed once the window has passed")
    func nothingIsSuppressedAfterTheWindow() {
        #expect(
            !TriggerOpenGate.shouldIgnoreDuplicate(source: .button, recentlyDismissed: false)
        )
        #expect(
            !TriggerOpenGate.shouldIgnoreDuplicate(
                source: .keyboardShortcut,
                recentlyDismissed: false
            )
        )
    }
}
