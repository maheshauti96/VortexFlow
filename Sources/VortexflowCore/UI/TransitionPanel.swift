import AppKit
import SwiftUI

/// The flying ghost of the window being switched to.
///
/// A throwaway panel holding the target window's thumbnail, animated from the card the user
/// clicked to where the window actually is. It exists only for the length of the animation.
///
/// Two properties matter more than anything else here:
///
/// - **It never takes input.** `ignoresMouseEvents` is set, so the click that started the
///   switch and everything after it goes where the user intended. A decorative animation that
///   swallowed a click would be far worse than no animation.
/// - **It never delays the switch.** The real activation runs before this appears; the ghost
///   is drawn on top of a window that is already coming forward.
@MainActor
final class TransitionPanel: NSPanel {

    private var completion: (() -> Void)?

    init(image: CGImage?, icon: NSImage?, startFrame: CGRect) {
        super.init(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above the switcher overlay, so the ghost is not clipped by a panel that is still
        // fading out.
        level = .popUpMenu
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications,
            .ignoresCycle, .stationary,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Keep the ghost out of its own captures, and out of anyone else's.
        sharingType = .none
        animationBehavior = .none
        // Decorative only: every click must pass straight through.
        ignoresMouseEvents = true

        let content = NSHostingView(rootView: TransitionGhostView(image: image, icon: icon))
        content.autoresizingMask = [.width, .height]
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the ghost, fly it to `endFrame`, then close.
    func run(to endFrame: CGRect, duration: TimeInterval, completion: (() -> Void)? = nil) {
        self.completion = completion
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // Ease out: fast to begin with, settling at the destination, which reads as the
            // window arriving rather than sliding to a stop.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(endFrame, display: true)
            // Fading out as it lands hands the eye over to the real window underneath, which
            // is by then already in place.
            animator().alphaValue = 0.05
        } completionHandler: { [weak self] in
            // `NSAnimationContext` calls back on the main thread but is not annotated as doing
            // so, hence the explicit assumption rather than a hop that would delay the cleanup
            // by a run loop pass.
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
    }

    private func finish() {
        completion?()
        completion = nil
        orderOut(nil)
        close()
    }
}

/// What the ghost draws: the window's own screenshot when there is one, its application icon
/// when there is not.
private struct TransitionGhostView: View {

    let image: CGImage?
    let icon: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))

            if let image {
                Image(decorative: image, scale: NSScreen.main?.backingScaleFactor ?? 2)
                    .resizable()
                    // Matching the card's treatment, so the ghost looks like the card it grew
                    // out of rather than a differently-cropped picture.
                    .aspectRatio(contentMode: .fit)
            } else if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}
