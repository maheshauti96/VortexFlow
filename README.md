# VortexFlow

A window switcher for macOS. Press a mouse button or a shortcut, see every window
you have open, pick one. Works with any mouse and any keyboard.

**[vortexflow.io](https://vortexflow.io/)** — download, privacy, blog, and how it compares.

Press a button, see every window you have open, pick one. Works with any mouse and any
keyboard.

---

## The problems

**Cmd-Tab switches applications, not windows.** Six Chrome windows are one icon behind
one app. Picking the right one means switching to Chrome first, then hunting through
what it brings forward.

**Windows of the same app are impossible to tell apart.** Same icon, similar titles,
and a switcher that shows you neither. Three terminals and four editors look like the
same two entries repeated.

**Your hand has to leave the mouse.** You are already holding it. Reaching for a key
combination to move between windows is a gesture in the wrong direction, and the
keyboard shortcuts get worse the more windows you have.

**You lose track of what is actually open.** Windows spread across Spaces and monitors,
and nothing shows them in one place. Minimized windows disappear from view entirely.

**Getting to a browser tab is two searches.** Switch to the browser, then find the tab
among thirty others, in a strip of favicons too small to read.

**Opening something that is not running yet is a different gesture altogether.** You
try the switcher, the app is not there, so you stop and go to Spotlight instead.

**The good alternatives cost money or only switch apps.** The ones that switch windows
properly tend to be paid, closed, and quietly sending usage data somewhere.

---

## What VortexFlow does about them

**Every window is its own card.** Four Finder windows are four cards, each with its own
title, its own thumbnail and its own place in the recency order. Minimized windows and
windows on other Spaces are included rather than hidden.

**Same-app windows are made distinguishable.** Each card takes a hint of colour from
its own icon, so a ring of windows is not a ring of identical white boxes. Browser
windows go further and show the icon of the site actually open in them, layered with
the browser's own icon — so three Chrome windows look like three different things,
because they are.

**Mouse-first, keyboard optional.** A spiral of every window you have open appears
around the pointer. Your hand never moves. If you would rather use the keyboard, a
global shortcut does the same job.

**Any mouse, any button.** Middle click works with no setup. For a side or thumb
button, press **Detect Button** and then press the button — no need to know its number.
VortexFlow watches for buttons earlier in the pipeline than most mouse utilities, so
buttons that other apps cannot see usually still work here. For a button your mouse
keeps to itself, assign it to a keyboard shortcut and use that instead.

**Five ways to show it,** because a good arrangement for six windows is a bad one for
twenty: a horizontal strip, a grid, a list with a large preview, and two round
arrangements that fan the windows around your cursor. Each one can show live
screenshots or large icons.

**Real previews.** Thumbnails come from ScreenCaptureKit, so you see what is in a
window before committing to it. The selected one keeps refreshing.

**Recency that is per window, not per app.** The window you were just in is one flick
away, and the second card is preselected — so the last window is already under the
pointer.

**Type to narrow it down.** Start typing and the list filters by application name,
window title, tab host, and the path of a tab's URL — so `workday` finds a page at
`/workday-task-board/`, not only a site whose host contains the word. Tab results are
labelled by site — `x.com` rather than "Google Chrome", which every tab would otherwise
say — and carry the site's icon layered with the browser's. Applications that are not
running show up as well, so you can launch one without leaving for Spotlight.

If nothing local matches, the list offers **Search the web**, **Open first result**
(Google's I'm Feeling Lucky — also Shift-Return), and the same query as a prompt to
ChatGPT, Claude or Grok. Return on Search the web still opens the results page; picking
Open first result skips it and goes to the destination.

**Right-click a card for the rest of the window.** A live preview, minimize and close,
Search through Tabs on that browser window — Chrome, Safari, Edge, Brave, Arc, Comet
and Chromium, including windows on other desktops —
play / pause / next if something is playing, and the same Move & Resize, Fill & Arrange,
Full Screen and Move to Display shapes as macOS. Full-screen windows stay in the menu:
VortexFlow leaves the Space first, then places the window — which is how you get a
live-share window off a shared screen.

**Private windows stay private.** Incognito and private-browsing windows are badged, and
their site icons are never fetched.

**A window making sound says so.** Playing and microphone-in-use show as badges on the
card. The card menu then carries transport for whatever is playing.

**Pin the applications you always want first.** Settings has a checklist of what is
running; those windows sit at the front of the ring, still ordered by recency among
themselves.

**The shortcut that opened it closes it.** Press again to dismiss without switching,
including when a mouse extra button is remapped to that shortcut.

**Local and private.** No accounts, no telemetry, no analytics. The app makes two
kinds of network call. To show the icon of a site open in your browser, VortexFlow
fetches that icon from that site's own address, with no cookies and nothing
identifying, and never for a private browsing window. To see if a newer signed build
exists, it reads `https://vortexflow.io/appcast.xml`. It downloads an update only if
you agree.

---

## Download

Two ways in. Same code either way.

**[Download the disk image](https://vortexflow.io/downloads/Vortexflow-1.0.1.dmg)**
(5.2 MB, universal, macOS 15 or newer). macOS will block it once. That is expected.
Click **Open Anyway**, then it stays open.

Or **[build from source](#building-from-source)**. One command, signed on your
machine. That path never shows the sheet.

### Disk image

1. Open the disk image and drag **VortexFlow** to your Applications folder.
2. Open it. macOS will refuse and say the developer cannot be verified. Leave
   that dialog. Do not choose Move to Bin.
3. Open **System Settings → Privacy & Security**, scroll down to **Security**,
   and click **Open Anyway** next to VortexFlow. Authenticate when asked.
4. Open the app again. Grant the permissions it asks for. The setup window
   explains what each one buys you.

You only do this once. macOS then remembers VortexFlow as an exception, as
described in [Apple's own documentation](https://support.apple.com/en-us/guide/mac-help/mh40616/mac).

VortexFlow is open source. Apple has not notarized the download, so macOS asks
you to confirm the first launch. On macOS 15, right-click → Open no longer skips
this. Older instructions elsewhere on the internet still describe that trick.

---

## Requirements

- macOS 15 (Sequoia) or newer
- Any Mac, Apple Silicon or Intel
- Any mouse with at least a middle click, or just the keyboard

---

## Permissions

VortexFlow asks for three permissions and explains each one on first launch. It runs
with any subset of them and tells you what you are missing rather than failing quietly.

| Permission | What it buys you | Without it |
| --- | --- | --- |
| **Input Monitoring** | Noticing your mouse button | Keyboard shortcut only |
| **Accessibility** | Listing individual windows, and raising the exact one you pick | Whole apps come forward instead of specific windows |
| **Screen Recording** | Window thumbnails | Cards show large app icons instead |

Automation permission is asked for separately, the first time it looks at browser
windows, and only powers tab search and site icons.

You can reopen the setup window at any time from the menu bar icon.

---

## Using it

By default VortexFlow works out what you meant from how long you held the button.

**Hold** it and the switcher tracks your hand: scroll to move the selection, release to
switch. Fast, once you know where you are going.

**Tap** it and the switcher stays up so you can read the titles and decide. Click a
card, or tap again, to switch.

| Action | Result |
| --- | --- |
| Hold the trigger button | Switcher appears by the cursor and follows the hold |
| Scroll | Move the selection, wrapping at both ends |
| Move onto a card | Select it |
| Release after holding | Switch to the selected window |
| Quick tap | Switcher stays open for browsing |
| Tap again while open | Switch to the selected window |
| Click a card | Switch to it |
| Right-click a card | Window menu: place, close, search that window's tabs, media |
| Keyboard shortcut | Open it, and press again to close it without switching |
| Arrow keys | Move the selection — a grid moves by a row, everything else by one window |
| Return | Switch to the selected window, or take the selected web / assistant offer |
| Shift-Return | Open the first web result for the query |
| Start typing | Filter by app, title, tab host, URL path or installed app |
| Delete / Command-Delete | Shorten the query, or wipe it |
| Command-A | Select the query, so the next keystroke replaces it |
| Escape, or click outside | Back out of search, then close without switching |

Once it is open you can finish the job entirely from the keyboard — arrows to choose,
Return to switch — or entirely from the mouse. Neither is the "real" way.

---

## Settings

- **Trigger button** — middle, side back, side forward, or **Detect Button** to use
  whatever you press next.
- **Behaviour** — automatic (tap keeps it open, hold switches on release), or force
  hold or toggle if you would rather it never guessed.
- **Keyboard shortcut** — pick a preset, or **Record Shortcut** and press the
  combination. Settings tells you whether the shortcut has actually fired, which
  matters more than it sounds: macOS reports a shortcut as registered even when
  another app has already claimed it, and then the keystroke simply never arrives.
  If it says the shortcut has not been seen after you press it, something else owns
  it — pick another. A mouse extra button mapped to that shortcut in the mouse's own
  software is treated the same way.
- **Arrangement** — strip, grid, list, circular or spiral. Also on the menu bar, so
  you can try them against live windows without opening Settings.
- **Each window shows** — a live preview, or a large icon. Icon View needs no Screen
  Recording.
- **Tint each window by its icon** — on by default. Turns itself off when you have
  macOS's Increase Contrast enabled.
- **Always show first** — pin running applications so their windows stay at the
  front of the list.
- **Windows to show** — 5 to 25.
- **Include the switcher in screenshots** — worth turning off while presenting, since
  the switcher lists the title of every window you have open.
- **Permissions** — live status, with links into System Settings.

### A note on the middle button

VortexFlow has to *consume* whichever button triggers it, or the click would also land
in whatever is under the cursor. With the default middle button, that means
middle-clicking a link to open it in a new tab stops working while VortexFlow is
running. Settings warns about this. Moving to a side button avoids it — press **Detect
Button** and then that button.

---

## Building from source

This path never shows the "cannot be verified" sheet. The build is signed on your
machine.

```sh
git clone https://github.com/maheshauti96/VortexFlow.git VortexFlow
cd VortexFlow
Scripts/create-signing-certificate.sh   # once
Scripts/build-app.sh --install
open /Applications/Vortexflow.app
```

Command Line Tools is enough — Xcode is not required.

```sh
Scripts/build-app.sh --debug         # debug configuration
Scripts/build-app.sh --native-arch   # skip the universal build
Scripts/make-dmg.sh                  # package a disk image
swift test                           # the test suite
```

### Run the signing script first

It matters more than it looks. macOS records privacy permissions against an app's
**code identity**, not its name or its path. An ad-hoc signature derives that identity
from the binary's own hash, so it changes on every build, and two things follow:

- You have to grant permissions again after every rebuild.
- Stale records pile up under the same bundle identifier until macOS refuses to add the
  app to the privacy lists at all — you click `+`, and the row never appears, with no
  error to explain it.

`create-signing-certificate.sh` makes a self-signed certificate called `Vortexflow Dev`
in your login keychain, and `build-app.sh` uses it automatically. The identity then
names the certificate rather than the binary, which is stable across rebuilds.

The certificate shows as untrusted in `security find-identity -v`. That is expected:
trust governs *verifying* signatures, not making them, and `codesign` is happy to sign
with it.

To use your own identity instead:

```sh
VORTEXFLOW_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" Scripts/build-app.sh
```

If you have a paid Apple Developer account, store notary credentials once:

```sh
xcrun notarytool store-credentials
```

Then set `VORTEXFLOW_NOTARY_PROFILE` to that profile name and run:

```sh
Scripts/make-dmg.sh
```

The disk image is notarized and stapled when those credentials are present. Without
them the image is signed but not notarized, and the Gatekeeper steps above still apply.

### If VortexFlow will not appear in a privacy list

Almost always leftover records from a build with a different identity:

```sh
tccutil reset All io.vortexflow.Vortexflow    # no sudo needed
Scripts/build-app.sh --install
```

Then grant permissions from VortexFlow's own setup window rather than the `+` button —
the app asks the system directly, which is more reliable than adding it by hand. Check
what it sees with:

```sh
/Applications/Vortexflow.app/Contents/MacOS/Vortexflow --probe
```

Run it from `/Applications` rather than `build/`. The build directory is replaced on
every build, and a privacy grant pointing at a path that no longer exists is dead
weight.

---

## How it works

```
Sources/VortexflowCore/
  Models/   WindowEntry, layouts, SelectionMath, IconTint, TriggerButton, KeyResponse,
            CardMenu, WindowTile, WindowSearch, WebSearch
  Core/     WindowRegistry, MRUTracker, TriggerMonitor, HotKeyMonitor, ThumbnailService,
            BrowserTabService, BrowserTabAlertService, BrowserFaviconService,
            ApplicationCatalog, ActivationService, PermissionsManager, SettingsStore,
            SwitcherController
  UI/       OverlayPanel, OverlayView, the card and wedge views, CardMenuHeaderView,
            MenuBarController, OnboardingView, SettingsView
```

A few decisions worth knowing before changing things.

**Window enumeration combines two APIs.** Accessibility supplies the window set — it is
the only one that sees minimized windows and the only one that can raise a specific
window. CGWindowList supplies front-to-back order and window IDs. They are stitched
together with `_AXUIElementGetWindow`, resolved at runtime because it is in no public
header. Matching on title and frame instead breaks on exactly the cases that matter:
several same-titled windows in one app, and tiled windows that share a frame.

**The event tap is installed at the HID level,** ahead of session-level taps. Mouse
utilities install their own tap at the session level and consume the extra buttons
there, so a session-level tap never sees them. This is why buttons that appear
undetectable to other apps often work here.

**Presentation stays under 150 ms because thumbnails are not on the critical path.** The
panel goes up showing icons, and captures land underneath as they finish. The panel and
its hosting view are built once at launch, not per presentation.

**Hover is polled, not tracked.** The overlay is a non-activating panel that never
becomes key, which makes AppKit's mouse tracking unreliable for it — especially while a
button is physically held down, as it always is in hold mode. The controller samples the
cursor at 60 Hz and hit-tests using the same arithmetic that drew the cards, so what is
drawn and what is clickable cannot disagree.

**Activation order is deliberate:** unhide the app, unminimize the window, raise the
window, *then* activate the app. Activating before raising produces a visible flicker as
the app's previously frontmost window appears and is immediately replaced.

---

## Not there yet

- Homebrew (the Privacy & Security → Open Anyway path above still applies to a disk image)
- Recency history that survives a restart
- Excluding specific apps
- Customising size, opacity and animation speed
- Full VoiceOver support

---

## Credits

Inspired by [Dory – App Switcher](https://apps.apple.com/app/dory-app-switcher/id6446071638)
by Segev Sherry, and by the window-preview work in
[alt-tab-macos](https://github.com/lwouis/alt-tab-macos) and
[DockDoor](https://github.com/ejbills/DockDoor).

## License

MIT. See [LICENSE](LICENSE).
