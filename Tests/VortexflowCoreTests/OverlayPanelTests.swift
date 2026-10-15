import AppKit
import SwiftUI
import Testing
@testable import VortexflowCore

@MainActor
@Suite("Overlay panel")
struct OverlayPanelTests {
    @Test("switcher and transition panels can join other applications' full-screen Spaces")
    func panelsJoinOtherApplications() {
        let overlay = OverlayPanel(content: EmptyView())
        let transition = TransitionPanel(image: nil, icon: nil, startFrame: .zero)
        defer {
            overlay.close()
            transition.close()
        }

        for panel in [overlay as NSPanel, transition as NSPanel] {
            #expect(panel.collectionBehavior.contains(.canJoinAllApplications))
            #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
            #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(panel.styleMask.contains(.nonactivatingPanel))
            #expect(!panel.canBecomeKey)
            #expect(!panel.hidesOnDeactivate)
        }
    }
}
