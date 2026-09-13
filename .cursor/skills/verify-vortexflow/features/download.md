# Download and Gatekeeper

A visitor can get the macOS disk image or build from source. Open Anyway is the expected one-click step for the disk image, not a footnote.

## Sub-features

- `download-cta` offers `Download for macOS` pointing at `/downloads/Vortexflow-1.0.1.dmg` on this site, next to `Build from source` (`#source`).
- `install-steps` lists drag-to-Applications, Open Anyway once, permissions, then middle-click.
- `gatekeeper` tells the visitor that sheet is expected and points at Privacy & Security → Open Anyway.

## How to get to it (user POV)

- Choose `Download` in the header, `Install notes` in the home hero, or go to `/download/`.
- Choose `Download for macOS` (`a[data-download]`).
- Scroll to `Gatekeeper: "the developer cannot be verified"` (`#gatekeeper`).

## Driving it with control-vortexflow

Preconditions:

- `control-vortexflow serve` has a URL.
- `control-vortexflow doctor` passed.

- **Open the page.** Run `control-vortexflow fetch /download/`. The HTML contains `<h1>Get VortexFlow</h1>` and `id="gatekeeper"`.
- **Drive the visitor path.** Run `control-vortexflow download-page`. It writes `download.json`, `download-before.png`, and `download-gatekeeper.png` under `artifacts/$VERIFY_RUN_ID/`.
- **Confirm CTA.** `before.downloadHref` contains `/downloads/Vortexflow-` and ends in `.dmg`. `before.gatekeeper` is `true`. GitHub Releases is no longer the primary file host.
- **Confirm Gatekeeper.** `after.heading` contains `the developer cannot be verified`. `download-gatekeeper.png` shows that heading, not only the hero.
- **Proof.** Keep the JSON and both screenshots. Fetching HTML without scrolling to `#gatekeeper` is incomplete.

## Gotchas

- `data-download` keeps the first-party `/downloads/` href unless GitHub later publishes a newer tag.
- Do not follow the download in Chrome. The proof is that the button points at a `.dmg` on this site, not that a file lands in `~/Downloads`.
- Inner pages hide header links below 900px. The recipe uses `/download/` directly, not the header button.
