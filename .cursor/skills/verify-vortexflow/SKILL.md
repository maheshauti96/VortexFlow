---
name: verify-vortexflow
description: Drive VortexFlow the way a user does — the macOS window-switcher overlay and the vortexflow.io site — and capture proof. Use when proving a UI, copy, overlay, download, compare, or spiral-demo change works.
---

# Verify VortexFlow

VortexFlow is a macOS menu-bar window switcher (`io.vortexflow.Vortexflow`) plus a static site in `site/` served as https://vortexflow.io/. This skill is for the next agent, mid-task, with no prior context.

**Primary drive surface for an agent:** the local site. It is the real visitor path, isolates cleanly, and does not need Accessibility.

**Native overlay:** the real app. Do not launch a second copy if `/Applications/Vortexflow.app` is already running. Use `native-probe` (exits, no overlay) or `native-preview` (separate bundle `io.vortexflow.VisualPreview`, synthetic windows, no event tap, no settings writes).

Unit tests (`swift test`) are not a user path. They do not count as proof of overlay or site behavior.

Read `features/` before driving. A proof that uses one convenient entry point is incomplete when the map lists others.

## Launch

Repo root is three levels above this file.

```sh
export VERIFY_RUN_ID="${VERIFY_RUN_ID:-$RANDOM}"
.cursor/skills/verify-vortexflow/scripts/control-vortexflow serve
```

Ready when the command prints `http://127.0.0.1:<port> pid <pid>` and `curl -fsS` of that URL returns HTML whose `<title>` contains `VortexFlow`.

The server is `python3 -m http.server` bound to `127.0.0.1`, directory `site/`. It is not the production host. GitHub star/release badges on the page may still call GitHub; the rest of the proof does not need that.

Teardown: `.cursor/skills/verify-vortexflow/scripts/control-vortexflow stop`

Do not `open /Applications/Vortexflow.app` and do not `Scripts/build-app.sh --install` from a verification run.

## Doctor

```sh
.cursor/skills/verify-vortexflow/scripts/control-vortexflow doctor
```

Pass only if all of these hold:

- This run's URL answers.
- Home `<title>` contains `VortexFlow`.
- Google Chrome exists at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` (override with `VERIFY_CHROME`).

`WARN: user VortexFlow is running` is not a doctor failure. It means: do not start another native copy. Site recipes still run.

If doctor fails, do not drive.

## Drive

Harness: `control-vortexflow`. Chrome runs headless with a throwaway `--user-data-dir`. It never uses the user's Chrome profile.

```sh
# static page
.cursor/skills/verify-vortexflow/scripts/control-vortexflow fetch /download/

# screenshot of a site path (second arg is an absolute png path)
.cursor/skills/verify-vortexflow/scripts/control-vortexflow screenshot /compare/ /tmp/compare.png

# mapped recipes (write into artifacts/$VERIFY_RUN_ID/)
.cursor/skills/verify-vortexflow/scripts/control-vortexflow download-page
.cursor/skills/verify-vortexflow/scripts/control-vortexflow home-spiral
```

Stable handles on the site:

| Handle | What it is |
|---|---|
| `#hero-h` | Home H1 |
| `#product-demo` | Interactive spiral figure, `aria-label="Interactive VortexFlow spiral"` |
| `#hero-spiral` | `<vortex-spiral>` custom element. Search box is `.qinput` in its shadow root, `aria-label="Search the example spiral"` |
| `#story-search` | Button that pauses the story and focuses search |
| `#story-caption` | Live caption next to the spiral |
| `nav a[href="/compare/"]` | Compare |
| `nav a[href="/blog/"]` | Blog |
| `nav a[href="/case-studies/"]` | Case studies |
| `a[data-download]` | Disk image on this site (`/downloads/`) |
| `#gatekeeper` | Gatekeeper heading on `/download/` |
| `ol.steps li` | Install / Open Anyway steps |
| `[data-theme-toggle]` | Light/dark toggle, `aria-label` switches with state |
| `table.compare` | Feature matrix on `/compare/` |

Native, only when doctor did not warn about `/Applications/Vortexflow.app`:

```sh
.cursor/skills/verify-vortexflow/scripts/control-vortexflow native-probe
.cursor/skills/verify-vortexflow/scripts/control-vortexflow native-preview
```

`native-probe` runs `build/Vortexflow.app/Contents/MacOS/Vortexflow --probe` and exits. Overlay accessibility name is `VortexFlow window switcher`. Visual preview quit item is `Quit visual preview` (Command-Q).

Prefer those names over click coordinates.

## Evidence

Put proof in `.cursor/skills/verify-vortexflow/artifacts/$VERIFY_RUN_ID/`. Cleanup must not delete that directory.

Proof standards:

- Drive the visitor path (click the spiral, open `/download/`, scroll to Gatekeeper). Do not call overlay internals or `swift test` and call it a UI proof.
- Capture the action and the resulting state: screenshot before and after, plus the JSON the recipe writes (`download.json`, `home-spiral.json`).
- For download, the JSON must show `gatekeeper: true`, an `h1` of `Get VortexFlow`, and a `downloadHref` pointing at a `.dmg` on this site (`/downloads/`). The Gatekeeper screenshot must include the heading `the developer cannot be verified`.
- For the home spiral, `ready.h1` must contain `Don't leave the pointer` and `typed.ok` must be true with `value` `snowfl`.
- Side effects: the site server writes nothing to disk except its log under `runs/`. A download click in Chrome is not followed to GitHub in these recipes.
- `swift test` and `--probe` are diagnostics, not feature proof.

## Cleanup

```sh
.cursor/skills/verify-vortexflow/scripts/control-vortexflow stop
```

That kills only the `python3 -m http.server` PID recorded in `runs/$VERIFY_RUN_ID/site.pid`. Chrome is spawned per drive and killed inside `drive-site.cjs`.

Never `killall Vortexflow` or `killall "Google Chrome"`. If you opened visual preview, quit that app by name `VortexFlow Visual Preview`, not VortexFlow.

Leave `artifacts/$VERIFY_RUN_ID/` in place.

## Helpers

Both scripts are executable. Invocation is always from the repo root, with `VERIFY_RUN_ID` set so two runs do not share a port file.

```sh
.cursor/skills/verify-vortexflow/scripts/control-vortexflow serve
.cursor/skills/verify-vortexflow/scripts/control-vortexflow doctor
.cursor/skills/verify-vortexflow/scripts/control-vortexflow download-page
.cursor/skills/verify-vortexflow/scripts/control-vortexflow stop
```

`drive-site.cjs` is called by `control-vortexflow`; do not invoke it with a relative URL.
