import AppKit
import SwiftUI

/// The switcher overlay in whichever arrangement the user picked (Requirement 3.1).
///
/// ## Why absolute positioning
///
/// Every card is placed at a rectangle that `OverlayLayout` computed, and those are the
/// same rectangles it hit-tests clicks against.
///
/// That is not a stylistic preference. The panel is non-activating and never key, so
/// clicks and hover are resolved by hit-testing a point against layout arithmetic
/// rather than by AppKit's view tree. Anything drawn at coordinates the layout does
/// not know about is, in practice, unclickable — which is exactly the class of bug
/// that made the drawer feel stuck, and exactly why the close affordance is drawn from
/// `closeButtonFrame(for:)` rather than as a `Button` inside the card.
///
/// ## No captions
///
/// There is deliberately no header and no keyboard hint. They described the overlay instead of
/// showing it, and on an overlay this short-lived that is noise.
///
/// One counter survives, in the hub: the number of windows the ring could not seat. It is not a
/// description of the overlay, it is the correction to one — the round arrangements are chosen
/// because they show everything at once, so the case where they do not has to be visible.
struct OverlayView: View {

    @ObservedObject var state: OverlayState
    /// Card the cursor is over, when it differs from the selection.
    var hoveredIndex: Int?

    /// Requirement 3.10: the theme follows the system appearance. Resolved once here
    /// and pushed into the environment so every card and caption agrees.
    @Environment(\.colorScheme) private var colorScheme

    private var palette: OverlayPalette { OverlayPalette.forScheme(colorScheme) }
    private var layout: OverlayLayout { state.layout }

    /// Cards, positioned. The strip is the only style with a non-zero scroll offset.
    private var cards: [OverlayLayout.PositionedCard] {
        layout.positionedCards(scrollOffset: state.scrollOffset)
    }

    var body: some View {
        ZStack {
            backdrop

            if state.entries.isEmpty {
                emptyState
            } else {
                // Rebuilt per presentation, which is what makes the entrance reliable rather
                // than intermittent. A fresh subtree reads `isRevealed` as it stands — already
                // false — instead of depending on a published change having been applied before
                // the forced layout pass. See `OverlayState.presentationID`.
                //
                // Deliberately not keyed on the entry list: filtering a search must not replay
                // the entrance, only a new presentation may.
                arrangement
                    .id(state.presentationID)
            }

            if state.showsSearch {
                searchField
            }
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        .environment(\.overlayPalette, palette)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("VortexFlow window switcher")
    }

    @ViewBuilder
    private var arrangement: some View {
        switch state.layoutStyle {
        case .strip: strip
        case .grid: grid
        case .list: list
        case .circular, .spiral: radial
        }
    }

    /// Whether anything is drawn behind the cards.
    ///
    /// The empty state always gets a plate whatever the style: "no switchable windows
    /// are open" is a sentence, and a sentence with nothing behind it is unreadable
    /// over an arbitrary desktop.
    private var showsBackdrop: Bool {
        state.entries.isEmpty || state.layoutStyle.drawsBackdrop
    }

    // MARK: - Search

    /// What has been typed so far.
    ///
    /// This is the one caption that earns its place: it exists only while a query is
    /// active, and without it there is no way to tell a filtered list from a short one, or
    /// to see that a stray keystroke was captured.
    /// The query, trimmed to what the pill can hold. See `OverlayLayout.Search.fittedQuery`.
    private var visibleSearchQuery: String {
        let font = NSFont.systemFont(
            ofSize: OverlayLayout.Search.queryFontSize,
            weight: .semibold
        )
        return OverlayLayout.Search.fittedQuery(
            state.searchQuery,
            panelWidth: layout.panelSize.width
        ) { text in
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
    }

    private var searchField: some View {
        let metrics = OverlayLayout.Search.self

        return VStack {
            HStack(spacing: metrics.iconSpacing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: metrics.iconFontSize, weight: .semibold))
                // The caret is grouped with the text at its own tighter spacing. Sharing the
                // magnifier's spacing put a visible gap between the last character and the caret,
                // which read as a trailing space that had been typed — the one thing a search field
                // must never lie about, since it is the only feedback that a keystroke landed.
                // Flush, not merely close. A caret with any gap in front of it reads as a space
                // that was typed, and this field's only job is to report what was typed.
                HStack(spacing: 0) {
                    Text(visibleSearchQuery)
                        .font(.system(size: metrics.queryFontSize, weight: .semibold))
                        .lineLimit(1)
                        // Selected text has to look selected, or Command-A is a keystroke with no
                        // visible answer — which is how it came to be reported as broken in the
                        // first place. Drawn as a highlight behind the glyphs, tight to them, the
                        // way selected text looks everywhere else.
                        .padding(.horizontal, state.isQuerySelected ? 3 : 0)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(palette.accent.opacity(state.isQuerySelected ? 0.32 : 0))
                        )
                    // A caret, so an empty-looking field still reads as one being typed into.
                    // Hidden while the query is selected: a selection and an insertion point are
                    // different states and showing both would say the next keystroke appends.
                    Rectangle()
                        .fill(palette.accent)
                        .frame(width: metrics.caretWidth, height: metrics.caretHeight)
                        .opacity(state.isQuerySelected ? 0 : 1)
                }
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .background(Capsule().fill(palette.chipFill))
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(showsBackdrop ? 0 : 0.25), radius: 6, y: 2)
            .frame(height: OverlayLayout.searchFieldHeight)

            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var backdrop: some View {
        if showsBackdrop {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                )
        }
    }

    /// Lift the cards off whatever is behind them.
    ///
    /// With no plate, a card can land on a same-coloured window and lose its edge, so
    /// each one casts its own shadow instead of borrowing the panel's.
    private var cardShadowRadius: CGFloat { showsBackdrop ? 0 : 9 }
    private var cardShadowOpacity: Double { showsBackdrop ? 0 : 0.34 }

    // MARK: - Cards

    private func card(_ card: OverlayLayout.PositionedCard) -> some View {
        let entry = state.entries[card.index]
        let isSelected = card.index == state.selectedIndex

        return WindowCardView(
            entry: entry,
            displayIcon: state.displayIcon(for: entry),
            thumbnail: state.thumbnails[entry.windowID],
            isSelected: isSelected,
            isHovered: card.index == hoveredIndex && !isSelected,
            badgeCount: state.badgeCount(for: entry),
            reduceMotion: state.reduceMotion,
            metrics: state.cardMetrics,
            display: state.display(for: entry),
            isIncognito: state.isIncognito(entry),
            isPlayingAudio: state.isPlayingAudio(entry),
            isUsingMicrophone: state.isUsingMicrophone(entry),
            tint: state.tint(for: entry)
        )
        .scaleEffect(isSelected ? state.selectedScale : 1.0)
        .shadow(
            color: .black.opacity(cardShadowOpacity),
            radius: cardShadowRadius,
            y: cardShadowRadius / 2
        )
        // Keep the enlarged card above its neighbours instead of clipped by them.
        .zIndex(isSelected ? 1 : 0)
        .animation(selectionAnimation, value: isSelected)
        .opacity(state.isRevealed ? 1 : 0)
        .scaleEffect(state.isRevealed ? 1 : OverlayReveal.initialScale)
        .animation(revealAnimation(forCardIndex: card.index), value: state.isRevealed)
        .position(x: card.frame.midX, y: card.frame.midY)
    }

    private func row(_ card: OverlayLayout.PositionedCard) -> some View {
        let entry = state.entries[card.index]
        let isSelected = card.index == state.selectedIndex

        return WindowRowView(
            entry: entry,
            displayIcon: state.displayIcon(for: entry),
            isSelected: isSelected,
            isHovered: card.index == hoveredIndex && !isSelected,
            badgeCount: state.badgeCount(for: entry),
            display: state.display(for: entry),
            isIncognito: state.isIncognito(entry),
            isPlayingAudio: state.isPlayingAudio(entry),
            isUsingMicrophone: state.isUsingMicrophone(entry),
            tint: state.tint(for: entry)
        )
        .frame(width: card.frame.width, height: card.frame.height)
        .opacity(state.isRevealed ? 1 : 0)
        // Rows arrive by sliding down the column rather than scaling; a list row growing
        // from its centre reads as a glitch in a stack of identical rows.
        .offset(y: state.isRevealed ? 0 : -6)
        .animation(revealAnimation(forCardIndex: card.index), value: state.isRevealed)
        .position(x: card.frame.midX, y: card.frame.midY)
    }

    /// The close affordance, on the selected card only — which is the card under the
    /// pointer, because hover drives selection.
    ///
    /// Drawn from the layout's rectangle rather than as an overlay inside the card, so
    /// that what is on screen and what the click handler tests are the same geometry.
    @ViewBuilder
    private func closeButton(for positioned: OverlayLayout.PositionedCard) -> some View {
        let entry = state.entries[positioned.index]

        if positioned.index == state.selectedIndex, state.canClose(entry) {
            let frame = layout.closeButtonFrame(for: positioned, selectedScale: state.selectedScale)

            CloseButtonView(isActive: state.hoveredCloseButtonIndex == positioned.index)
                .zIndex(2)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    @ViewBuilder
    private var positionedCards: some View {
        ForEach(cards, id: \.index) { positioned in
            card(positioned)
            closeButton(for: positioned)
        }
    }

    // MARK: - Strip

    private var strip: some View {
        ZStack(alignment: .topLeading) {
            positionedCards
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        // Cards scrolled past the ends must not spill outside the panel.
        .clipped()
        .animation(scrollAnimation, value: state.scrollOffset)
    }

    // MARK: - Grid

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            positionedCards
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
    }

    // MARK: - List

    private var list: some View {
        ZStack(alignment: .topLeading) {
            // Sidebar plate, so the row column reads as separate from the preview. Starts
            // below the search field when one is showing.
            let sidebarHeight = layout.panelSize.height - layout.searchChrome

            Rectangle()
                .fill(palette.strongBorder.opacity(0.18))
                .frame(width: OverlayLayout.List.sidebarWidth, height: sidebarHeight)
                .offset(y: layout.searchChrome)

            Rectangle()
                .fill(palette.border)
                .frame(width: 1, height: sidebarHeight)
                .offset(x: OverlayLayout.List.sidebarWidth, y: layout.searchChrome)

            ForEach(cards, id: \.index) { positioned in
                row(positioned)
                closeButton(for: positioned)
            }

            WindowPreviewView(
                entry: state.selectedEntry,
                displayIcon: selectedDisplayIcon,
                thumbnail: selectedThumbnail,
                overlaysCaption: false,
                showsLiveBadge: state.viewMode.usesThumbnails,
                showsIconInsteadOfThumbnail: !state.viewMode.usesThumbnails
                    || state.selectedEntry?.isApplication == true,
                display: selectedDisplay,
                isIncognito: state.selectedEntry.map(state.isIncognito) ?? false,
                isPlayingAudio: state.selectedEntry.map(state.isPlayingAudio) ?? false,
                isUsingMicrophone: state.selectedEntry.map(state.isUsingMicrophone) ?? false
            )
            .frame(width: layout.listDetailFrame.width, height: layout.listDetailFrame.height)
            .position(x: layout.listDetailFrame.midX, y: layout.listDetailFrame.midY)
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
    }

    // MARK: - Circular and spiral

    private var radial: some View {
        ZStack(alignment: .topLeading) {
            // Halo first: translucent, so it cannot sit on a card. Ring next so its
            // inward bloom cannot land on the title — the well's opaque core covers it.
            // Well after the wedges so a turn-0 shadow cannot land on the caption.
            // Coupling then caption then close.
            HubRingHalo(
                frame: layout.radialHubFrame,
                ambience: hubAmbience,
                angle: state.radialRingAngle,
                isRevealed: state.isRevealed,
                reduceMotion: state.reduceMotion,
                isVisible: state.isVisible
            )
            .animation(selectionAnimation, value: state.radialRingAngle)
            .animation(ambienceAnimation, value: hubAmbience)
            .zIndex(0)

            // Isolate wedge-local z-indices below every front hub layer. Without this parent
            // level, the selected wedge's zIndex(1) rose above the later well and erased the
            // inward glow and coupling along exactly the selected axis.
            ForEach(layout.radialSeats, id: \.index) { positioned in
                wedge(positioned)
            }
            .zIndex(1)

            // The inner turn: pinned shortcuts in the seam. Below the hub layers so the halo
            // stays on top, and it enters the way the wedges do — blooming out from the hub.
            ForEach(layout.shortcutSlots, id: \.offset) { tile in
                let slot = tile.offset
                let shortcut = state.pinnedShortcut(inSlot: slot)
                ShortcutTileView(
                    shortcut: shortcut,
                    favicon: { if case .link(let url) = shortcut { return state.slotIcons[url] }; return nil }(),
                    seat: tile,
                    centre: layout.radialCentre,
                    panelSize: layout.panelSize,
                    scale: layout.radialScale,
                    isHovered: state.hoveredSlot == slot && state.draggingSlot == nil,
                    isDragging: state.draggingSlot == slot,
                    isDropTarget: state.draggingSlot != nil && state.draggingSlot != slot && state.hoveredSlot == slot
                )
                .opacity(state.isRevealed ? 1 : 0)
                .scaleEffect(state.isRevealed ? 1 : OverlayReveal.initialScale, anchor: revealAnchor)
                .animation(
                    revealAnimation(forVisibleOffset: slot, count: layout.shortcutSlotCount),
                    value: state.isRevealed
                )
            }
            .zIndex(1.5)

            if let plus = layout.shortcutPlusFrame {
                ShortcutPlusView(
                    frame: plus,
                    isHovered: state.hoveredSlot == state.pinnedShortcuts.count && state.draggingSlot == nil
                )
                .opacity(state.isRevealed ? 1 : 0)
                .animation(hubRevealAnimation, value: state.isRevealed)
            }

            HubRing(
                frame: layout.radialHubFrame,
                ambience: hubAmbience,
                angle: state.radialRingAngle,
                isRevealed: state.isRevealed,
                reduceMotion: state.reduceMotion,
                isVisible: state.isVisible
            )
            .animation(selectionAnimation, value: state.radialRingAngle)
            .animation(ambienceAnimation, value: hubAmbience)
            .zIndex(2)

            // The watermark is passed *into* the well rather than layered over it. It used to draw
            // here, at zIndex 3.5, between the well and the caption — which is what forced its
            // opacity to be a contrast budget, because nothing stood between it and 9pt type. The
            // well now stacks it between its own frosted substrate and its scrim, so the scrim
            // protects the caption from the icon exactly as it protects it from the wallpaper.
            HubWell(
                frame: layout.radialHubFrame,
                ambience: hubAmbience,
                backdropIcon: hubBackdropIcon,
                isRevealed: state.isRevealed,
                reduceMotion: state.reduceMotion,
                increaseContrast: state.increaseContrast
            )
            .animation(ambienceAnimation, value: hubAmbience)
            .zIndex(3)

            if state.selectedEntry != nil {
                HubCoupling(
                    centre: layout.radialCentre,
                    ambience: hubAmbience,
                    angle: state.radialRingAngle,
                    innerRadius: selectedCouplingInnerRadius,
                    isRevealed: state.isRevealed,
                    reduceMotion: state.reduceMotion,
                    isVisible: state.isVisible
                )
                .animation(selectionAnimation, value: state.radialRingAngle)
                .animation(ambienceAnimation, value: hubAmbience)
                .zIndex(4)
            }

            hubCaption
                // Cross-fades the window caption and a slot caption as the pointer moves between
                // the ring and the seam, the same way one window's caption fades into another's.
                .animation(captionChangeAnimation, value: state.hoveredSlot)
                .zIndex(5)

            // Drawn last so it sits above the wedge it belongs to.
            ForEach(cards, id: \.index) { positioned in
                closeButton(for: positioned)
            }
            .zIndex(6)
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
    }

    private func wedge(_ positioned: OverlayLayout.PositionedSeat) -> some View {
        let entry = state.entries[positioned.index]
        let isSelected = positioned.index == state.selectedIndex

        return WindowWedgeView(
            entry: entry,
            displayIcon: state.displayIcon(for: entry),
            seat: positioned.seat,
            centre: layout.radialCentre,
            panelSize: layout.panelSize,
            isSelected: isSelected,
            isHovered: positioned.index == hoveredIndex && !isSelected,
            badgeCount: state.badgeCount(for: entry),
            reduceMotion: state.reduceMotion,
            metrics: state.cardMetrics.scaled(by: layout.radialScale),
            display: state.display(for: entry),
            isIncognito: state.isIncognito(entry),
            isPlayingAudio: state.isPlayingAudio(entry),
            isUsingMicrophone: state.isUsingMicrophone(entry),
            tint: state.tint(for: entry),
            // Scaled with the arrangement: a flat 9pt blur on a 48pt hub is 19% of the
            // radius, and even with the well in front the outer edge would swallow a
            // neighbour. The floor keeps a shrunken ring from losing lift entirely.
            shadowRadius: max(4, cardShadowRadius * layout.radialScale),
            shadowOpacity: palette.wedgeShadowOpacity,
            increaseContrast: state.increaseContrast
        )
        // Wedges are painted in seat order, so without this the selected one's glow would
        // be overpainted by whichever wedge happens to come after it.
        .zIndex(isSelected ? 1 : 0)
        .animation(selectionAnimation, value: isSelected)
        .opacity(state.isRevealed ? 1 : 0)
        // Anchored on the hub, so the ring blooms outward from the pointer instead of each
        // wedge inflating where it stands.
        .scaleEffect(state.isRevealed ? 1 : OverlayReveal.initialScale, anchor: revealAnchor)
        .animation(
            revealAnimation(forVisibleOffset: positioned.seat.offset),
            value: state.isRevealed
        )
    }

    /// Colour of every glow the hub throws, taken from the window under the pointer.
    ///
    /// Keyed off `state.selectedEntry` rather than `hoveredIndex`, which is the correct source
    /// here for two independent reasons. Hovering a wedge *is* selecting it — `SwitcherController`
    /// assigns selection from the hover sample — so this already tracks the pointer. And unlike
    /// the hover index, which is deliberately unpublished so a 60Hz sampler cannot invalidate the
    /// overlay, the selection publishes; a hue keyed off the index alone could keep the previous
    /// colour until something else happened to trigger a render.
    ///
    /// Resolved here, once, rather than in each hub layer: `HubRing` and `HubCoupling` rebuild
    /// their bodies 24 times a second under `TimelineView`, and this does colour-space conversion.
    private var hubAmbience: Color {
        guard let entry = state.selectedEntry else { return palette.hubRing }
        return palette.hubAmbience(for: state.tint(for: entry))
    }

    /// The hovered window's icon, as a watermark for the middle.
    ///
    /// Suppressed under Increase Contrast. A user who asked the system for more contrast has
    /// asked for the opposite of a decorative shape underneath 9pt type, and unlike the ambience
    /// this cannot express itself by hue alone.
    private var hubBackdropIcon: NSImage? {
        guard !state.increaseContrast else { return nil }
        return selectedDisplayIcon
    }

    /// A hue change is a change of light with no direction to it, so it eases in and out rather
    /// than decelerating, and it is slower than the ring's travel: the glow settling into a new
    /// colour should trail the hotspot arriving, not race it.
    private var ambienceAnimation: Animation? {
        state.reduceMotion ? nil : .easeInOut(duration: 0.30)
    }

    private var selectedCouplingInnerRadius: CGFloat {
        guard let index = state.selectedIndex,
              let seat = layout.radialSeats.first(where: { $0.index == index })?.seat
        else {
            return layout.radialHubFrame.width / 2
        }
        return seat.innerRadius
    }

    /// What the hollow middle says.
    ///
    /// The middle is not a preview — the arrangement exists because a large picture of the
    /// window you have already found is the least useful thing on screen. It is a caption,
    /// and it is load-bearing rather than decorative: a wedge has room for an application
    /// name and no more, so three Chrome windows are three identical icons until something
    /// spells out which one is under the pointer. That is what this does.
    ///
    /// With nothing selected it disappears entirely and the middle really is a hole.
    @ViewBuilder
    private var hubCaption: some View {
        if let slot = state.hoveredSlot,
           slot == state.pinnedShortcuts.count || layout.shortcutSlots.indices.contains(slot) {
            slotCaption(for: state.pinnedShortcut(inSlot: slot))
        } else if let entry = state.selectedEntry {
            let frame = layout.radialHubFrame

            // Sizes, line counts and how far each line may shrink all come from `HubTypography`,
            // which owns the one thing worth getting right here: every line shrinks to fit before it
            // truncates, but only as far as the overlay's own legibility floors.
            let scale = layout.radialScale
            let type = HubTypography(radialScale: scale)
            let summary = state.hubSummary(for: entry)
            // Windows the ring could not seat. See `RadialLayout`'s note on the cap: the
            // arrangement stops adding wedges once they would be too shallow to read as cards,
            // and this is the only thing on screen that admits the ring is not the whole list.
            let pagedLine: String? = layout.hiddenCount > 0
                ? "+\(layout.hiddenCount) more"
                : nil
            // Same threshold the title uses to give up a line: below it the disc is too narrow for
            // the age as well as the warning, and a half-truncated age is worse than none. The
            // paged count displaces the age for the same reason — both cannot fit, and how stale a
            // window is matters less than whether there are windows you cannot see.
            let statusLine = summary.statusLine(
                includingAge: type.isRoomy && pagedLine == nil
            )

            VStack(spacing: 3 * scale) {
                // What this window belongs to. For a browser window that is the site rather than
                // the browser, which is the identifying half: a Chrome window whose title never
                // mentions GitHub is told apart by `github.com` and not at all by "Google Chrome".
                // Absent entirely when it would only repeat the wedge — see `HubSummary.sourceLine`.
                if let sourceLine = summary.sourceLine {
                    Text(sourceLine)
                        .font(.system(size: type.sourceSize, weight: .medium))
                        .lineLimit(1)
                        // A clipped host reads as a different host. Shrinking first means
                        // "github.com" stays "github.com" rather than becoming "githu…".
                        .minimumScaleFactor(type.sourceMinimumScale)
                        .truncationMode(.tail)
                        .foregroundStyle(palette.hubSecondaryText)
                        .contentTransition(.opacity)
                }

                // The title is the one thing a wedge has no room for, so the hub still spends most
                // of what it has on this.
                Text(entry.displayTitle)
                    .font(.system(size: type.titleSize, weight: .semibold))
                    .lineLimit(type.titleLines)
                    // The end of a title is often what tells it from its neighbours — two Slack
                    // channels differ in their last few words — so it shrinks to fit before it
                    // gives that end up, down to the floor and no further.
                    .minimumScaleFactor(type.titleMinimumScale)
                    .multilineTextAlignment(.center)
                    // Cross-faded rather than replaced. Without this the title hard-cuts on every
                    // selection change, and unlike the entrance that happens continuously — once
                    // per wedge as the pointer crosses the ring.
                    .contentTransition(.opacity)
                    // A window with no title of its own falls back to its application name, so
                    // dropping the line above can never leave the middle blank.
                    .foregroundStyle(palette.text)

                if entry.isApplication || entry.isMinimized || state.isIncognito(entry)
                    || statusLine != nil || pagedLine != nil {
                    HStack(spacing: 4) {
                        if entry.isApplication {
                            ApplicationBadge()
                        }
                        if state.isIncognito(entry) {
                            IncognitoBadge(size: max(14, 15 * scale))
                        }
                        if entry.isMinimized {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(palette.hubSecondaryText)
                        }
                        // The one warning on screen that selecting this replaces the whole screen
                        // rather than just raising a window, and how stale it is if it does.
                        if let statusLine {
                            Text(statusLine)
                                .font(.system(size: type.statusSize, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(type.statusMinimumScale)
                                .truncationMode(.tail)
                                .foregroundStyle(palette.hubSecondaryText)
                                .contentTransition(.opacity)
                        }
                        // How many windows are off the ring. Not a decoration and not a
                        // progress read-out: the round arrangements are chosen because they
                        // show everything at once, so the one case where that is untrue has
                        // to say so or the omission is indistinguishable from a bug.
                        if let pagedLine {
                            Text(pagedLine)
                                .font(.system(size: type.statusSize, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(type.statusMinimumScale)
                                .truncationMode(.tail)
                                .foregroundStyle(palette.hubSecondaryText)
                                .contentTransition(.opacity)
                        }
                    }
                }
            }
            // Scoped to the selected window's identity rather than to the index: a search that
            // filters the list can leave the same index pointing at a different window, and that is
            // a change of caption like any other.
            //
            // Placed here so it governs the contents only. The disc's own entrance is animated
            // below against `isRevealed`, and the two must not drive each other — a caption change
            // is not a reason to replay the entrance.
            .animation(captionChangeAnimation, value: entry.id)
            .padding(.horizontal, 14 * scale)
            // Width of the opaque well, so the title wraps inside the circle instead
            // of sitting on a rounded rect in the middle of the void.
            .frame(width: frame.width * HubChrome.wellOpaqueFraction)
            .frame(width: frame.width, height: frame.height)
            .opacity(state.isRevealed ? 1 : 0)
            .animation(hubRevealAnimation, value: state.isRevealed)
            .position(x: frame.midX, y: frame.midY)
        }
    }

    /// The hub answering for a slot instead of a window while the pointer is on one.
    ///
    /// The slots are the only thing on the ring that carries no label, and the hub is already
    /// where "what is under my pointer" is answered. The third line doubles as the only
    /// instruction the feature has: nobody has to guess what the plus does or that pins move.
    private func slotCaption(for shortcut: PinnedShortcut?) -> some View {
        let frame = layout.radialHubFrame
        let scale = layout.radialScale
        let type = HubTypography(radialScale: scale)
        return VStack(spacing: 3 * scale) {
            Text(shortcut?.kindLabel ?? "Empty slot")
                .font(.system(size: type.sourceSize, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(palette.hubSecondaryText)
            Text(shortcut?.title ?? "Pin a link, app or shortcut")
                .font(.system(size: type.titleSize, weight: .semibold))
                .lineLimit(type.titleLines)
                .minimumScaleFactor(type.titleMinimumScale)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.text)
            Text(shortcut == nil ? "Click to choose" : "Click to open · drag to reorder")
                .font(.system(size: type.statusSize, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(type.statusMinimumScale)
                .foregroundStyle(palette.hubSecondaryText)
        }
        .padding(.horizontal, 14 * scale)
        .frame(width: frame.width * HubChrome.wellOpaqueFraction)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
    }

    // MARK: - Selected window

    private var selectedDisplayIcon: NSImage? {
        guard let entry = state.selectedEntry else { return nil }
        return state.displayIcon(for: entry)
    }

    private var selectedThumbnail: CGImage? {
        guard let entry = state.selectedEntry else { return nil }
        return state.thumbnails[entry.windowID]
    }

    private var selectedDisplay: DisplayInfo? {
        guard let entry = state.selectedEntry else { return nil }
        return state.display(for: entry)
    }

    /// Requirement 15.1 / 15.2: no scale animation under Reduce Motion.
    private var selectionAnimation: Animation? {
        state.reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78)
    }

    /// Requirement 15.3: jump the scroll position instead of animating it.
    private var scrollAnimation: Animation? {
        state.reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    // MARK: - Entrance

    /// The cards' entrance, staggered so they arrive one after another.
    ///
    /// Ordered by position in the visible run rather than by entry index, so the run always
    /// starts at the first card on screen — otherwise a grid paged to entries 12–20 would sit
    /// through twelve cards' worth of delay before drawing anything.
    private func revealAnimation(forCardIndex index: Int) -> Animation? {
        revealAnimation(forVisibleOffset: max(0, index - layout.visibleRange.lowerBound))
    }

    private func revealAnimation(forVisibleOffset offset: Int, count: Int? = nil) -> Animation? {
        // Requirement 15.1: no entrance under Reduce Motion. The cards are simply there.
        guard !state.reduceMotion else { return nil }
        return .easeOut(duration: OverlayReveal.duration).delay(
            OverlayReveal.delay(
                forOffset: offset,
                count: max(1, count ?? cards.count),
                reduceMotion: false
            )
        )
    }

    private var hubRevealAnimation: Animation? {
        guard !state.reduceMotion else { return nil }
        return .easeOut(duration: OverlayReveal.duration).delay(OverlayReveal.hubDelay)
    }

    /// The hub swapping one window's caption for another.
    ///
    /// `easeInOut` rather than `easeOut`: this is a change of contents with no direction to it, so
    /// there is nothing for a decelerating curve to describe. Requirement 15.1 — under Reduce Motion
    /// the caption simply changes.
    private var captionChangeAnimation: Animation? {
        state.reduceMotion ? nil : .easeInOut(duration: OverlayReveal.captionChange)
    }

    /// The hub, as a fraction of the panel. The spiral's wedges scale about this.
    private var revealAnchor: UnitPoint {
        let panel = layout.panelSize
        guard panel.width > 0, panel.height > 0 else { return .center }
        let centre = layout.radialCentre
        return UnitPoint(x: centre.x / panel.width, y: centre.y / panel.height)
    }

    // MARK: - Empty state

    /// Requirement 1.8, and the no-matches case.
    ///
    /// The two are distinguished on purpose: "nothing is open" and "nothing matches what
    /// you typed" call for different reactions, and showing the first when the second is
    /// true reads as a bug.
    private var emptyState: some View {
        VStack(spacing: 6) {
            if state.tabScope != nil || state.isAwaitingTabScope || state.tabScopeFailure != nil {
                tabScopeEmptyView
            } else if state.isSearching {
                searchMissView
            } else {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(palette.secondaryText)
                Text("No switchable windows are open")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // Clear of the search field when one is showing.
        .padding(.top, layout.searchChrome)
    }

    /// A tab-scoped list that is empty. Distinguished from "no switchable windows" because
    /// the windows are still open — they were just asked not to be shown.
    @ViewBuilder
    private var tabScopeEmptyView: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(palette.secondaryText)
        if let failure = state.tabScopeFailure {
            Text(failure)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.text)
        } else if !state.hasLoadedTabs || state.isAwaitingTabScope {
            Text("Looking for tabs…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
        } else if state.isSearching {
            Text("No tabs in this window match that search")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.text)
        } else {
            Text("No tabs in this window")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
        }
        Text("Esc to go back")
            .font(.system(size: 10))
            .foregroundStyle(palette.secondaryText)
    }

    /// What an unresolved or final search miss says.
    ///
    /// Browser tabs and the application catalog arrive asynchronously. Until both have settled,
    /// this must read as progress rather than a dead end and must not advertise Return: the
    /// controller intentionally ignores Return during the same interval. Once local sources have
    /// all missed, the existing web fallback becomes the final offer.
    @ViewBuilder
    private var searchMissView: some View {
        if state.isResolvingSearch {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.secondaryText)

            Text("Looking for matches…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)

            Text("Checking browser tabs and installed applications")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryText)

            Text("Esc to clear")
                .font(.system(size: 10))
                .foregroundStyle(palette.secondaryText)
        } else {
            let destination = WebSearch.destination(for: state.searchQuery)

            Image(systemName: destination == nil ? "magnifyingglass" : "arrow.up.forward.app")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.secondaryText)

            Text("No windows or applications match")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)

            if let destination {
                // Stacked rather than one line, and wrapping: the empty-state panel is 320pt wide
                // and a query plus its preamble does not fit beside the key chip.
                VStack(spacing: 4) {
                    Text("Return")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(palette.accentFill)
                        )
                        .foregroundStyle(palette.onAccentText)

                    Text(promptText(for: destination))
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.top, 2)
            }

            Text("Esc to clear")
                .font(.system(size: 10))
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func promptText(for destination: WebSearch.Destination) -> String {
        // Truncated here rather than by the layout: the panel is sized for a short message, and
        // a pasted paragraph would otherwise stretch it off the screen.
        let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.count > 28 ? query.prefix(28) + "…" : query[...]

        switch destination {
        case .address: return "to open \(shown)"
        case .search: return "to search the web for \(shown)"
        case .firstResult: return "to open the first result for \(shown)"
        case .prompt(let provider, _): return "to ask \(provider.displayName) about \(shown)"
        }
    }
}
