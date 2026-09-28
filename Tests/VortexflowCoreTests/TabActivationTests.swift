import Foundation
import Testing
@testable import VortexflowCore

/// The order of operations when switching to a tab, which is the whole of the bug it fixes.
///
/// Reported as: with several Chrome windows open, searching for a ChatGPT tab opened a *different*
/// Chrome window, and repeating the search opened the right tab. The cause was that the browser's
/// window was raised before the browser was activated, and raising a window while its application
/// is in the background does not move it when the window is on another desktop. Measured against a
/// live Chrome with one window per desktop: raise-then-activate put the wrong window in front 3
/// times out of 3, activate-then-raise put the right one in front 3 times out of 3.
///
/// So what is asserted here is sequence, not syntax. Nothing else in the test suite can see it —
/// the sequence only proves itself against a running browser with windows spread over two desktops.
struct TabActivationTests {

    private func tab(
        browser: BrowserTab.Browser = .chrome,
        processIdentifier: pid_t = 855,
        windowIdentifier: Int = 1_263_775_930,
        tabIndex: Int = 6
    ) -> BrowserTab {
        BrowserTab(
            browser: browser,
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier,
            tabIndex: tabIndex,
            title: "ChatGPT",
            url: "https://chatgpt.com/"
        )
    }

    private func index(
        of step: BrowserTabService.ActivationStep,
        in steps: [BrowserTabService.ActivationStep]
    ) -> Int? {
        steps.firstIndex(of: step)
    }

    /// The regression itself: activation must precede the raise.
    @Test func theBrowserIsActivatedBeforeItsWindowIsRaised() throws {
        let steps = BrowserTabService.activationSteps(for: tab())
        let activate = try #require(index(of: .activateApplication, in: steps))
        let raise = try #require(index(of: .raiseWindow, in: steps))
        #expect(
            activate < raise,
            "activation must come first, or an off-desktop window will not be moved: \(steps)"
        )
    }

    /// Selecting the tab has to happen before the raise too, so the window arrives already showing
    /// the tab the user picked rather than visibly switching to it afterwards.
    @Test func theTabIsSelectedBeforeTheWindowIsRaised() throws {
        let steps = BrowserTabService.activationSteps(for: tab())
        let select = try #require(index(of: .selectTabByIndex(6), in: steps))
        let raise = try #require(index(of: .raiseWindow, in: steps))
        #expect(select < raise)
    }

    /// Three operations, no waiting and no sleeping — the part that had to be measured rather than
    /// reasoned about. A "wait until frontmost" guard looked necessary and did nothing: the browser
    /// reports itself frontmost as soon as activation is *requested*, so the loop ran zero times and
    /// what it guarded still failed. Activating first is sufficient on its own.
    @Test func theSequenceIsExactlyActivateSelectRaise() {
        #expect(
            BrowserTabService.activationSteps(for: tab())
                == [.activateApplication, .selectTabByIndex(6), .raiseWindow]
        )
    }

    /// Safari names the selected tab by object rather than by index, and that difference has to
    /// survive the reordering.
    @Test func safariKeepsItsOwnSelectionForm() throws {
        let steps = BrowserTabService.activationSteps(for: tab(browser: .safari, tabIndex: 3))
        #expect(steps == [.activateApplication, .selectTabByObject(3), .raiseWindow])
    }

    /// Terminal selects by setting `selected` on the tab, not an index on the window.
    @Test func terminalKeepsItsOwnSelectionForm() {
        let steps = BrowserTabService.activationSteps(
            for: tab(browser: .terminal, windowIdentifier: 7659, tabIndex: 2)
        )
        #expect(steps == [.activateApplication, .markTabSelected(2), .raiseWindow])
    }

    /// Accessibility tabs keep a CGWindowID for listing. Activation has to use the browser's own
    /// window id, or the window is never found and the click never leaves this desktop.
    @Test func aPairedAccessibilityTabActivatesThroughTheScriptedWindowId() throws {
        let listed = BrowserTab(
            browser: .chrome,
            processIdentifier: 855,
            windowIdentifier: 5_575,
            tabIndex: 3,
            title: "ChatGPT",
            url: "https://chatgpt.com/",
            usesNativeWindowIdentifier: true,
            scriptedWindowIdentifier: 1_263_775_930,
            scriptedTabIndex: 6
        )
        let target = try #require(listed.scriptedActivation)

        #expect(target.windowIdentifier == 1_263_775_930)
        #expect(target.tabIndex == 6)
        #expect(!target.usesNativeWindowIdentifier)
        #expect(
            BrowserTabService.activationSteps(for: target)
                == [.activateApplication, .selectTabByIndex(6), .raiseWindow]
        )
    }

    /// The process survives the rewrite to a scripted target. Without it, activation would be sent
    /// to whichever instance of the browser Launch Services resolves — the bug that made a second
    /// Chrome answer for the user's own.
    @Test func theScriptedTargetKeepsItsProcess() throws {
        let listed = BrowserTab(
            browser: .chrome,
            processIdentifier: 37_835,
            windowIdentifier: 5_575,
            tabIndex: 1,
            title: "ChatGPT",
            url: "https://chatgpt.com/",
            usesNativeWindowIdentifier: true,
            scriptedWindowIdentifier: 1_263_791_277,
            scriptedTabIndex: 4
        )
        let target = try #require(listed.scriptedActivation)
        #expect(target.processIdentifier == 37_835)
    }

    /// A tab whose process was never identified cannot be addressed, and activation must decline
    /// rather than fall back to the browser's name — falling back is what sent the switch to the
    /// wrong instance.
    @Test func aTabWithNoProcessIsNotActivated() async {
        let service = BrowserTabService()
        let orphan = BrowserTab(
            browser: .chrome,
            windowIdentifier: 1_263_775_930,
            tabIndex: 1,
            title: "ChatGPT",
            url: "https://chatgpt.com/"
        )
        #expect(orphan.processIdentifier == 0)
        #expect(await service.activate(orphan) == false)
    }
}
