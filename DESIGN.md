# DESIGN.md

Design direction for the session-pet GitHub Pages site (`docs/index.html`).

Nothing here is invented. Every entry is derived from decisions the repo had
already made, with the source line given. Where the repo does not answer a
question, the question sits in "Open" instead of being guessed.

Sources are cited against commit `31236ab` (the state of the repo when this
file was written). `docs/index.html` line numbers refer to the page as it
existed before the rewrite: `git show 31236ab:docs/index.html`.

## Identity

session-pet is a pixel-art desktop pet that watches every Claude Code and
Codex session on one machine, dings when an agent needs the human, and levels
up as sessions finish. It is a developer tool that lives on the desktop, not a
web app.

- Pixel art is the product, not a decoration: sprites are 16px-wide pixel maps
  in `native/assets.json`, and the page renders them from that same source.
  Source: `docs/index.html:234-235`, `docs/index.html:568-569`,
  `CUSTOMIZING.md:29-30, 35-37`.
- The page is documentation for the tool. The owner's stated direction for it:
  informative, interactive enough to be useful, real documentation rather than
  a brochure.
- Two platforms, one pet: Swift/AppKit on macOS, Rust/GTK on Linux, one
  `.state/state.json`. Source: `ARCHITECTURE.md:5-14`.

## Personality

Taken from how the repo already writes about itself, not from a new tone of
voice:

- Blunt and specific, with numbers attached to behavior: "any false
  needs-input or ready ding is release-blocking". Source: `README.md:103-104`.
- States its limits out loud: the README ships a "Non-goals" section ("No
  17-provider support", "No more gamification"). Source: `README.md:92-101`.
- Explains mechanism rather than benefit: `ARCHITECTURE.md` leads with the
  traps that cost real debugging. Source: `ARCHITECTURE.md:44-58`.
- Playful only in the product itself (the pet hops, has a name, wanders); the
  prose around it stays flat and technical.

## Palette

Lifted verbatim from the existing page tokens, which in turn track the app's
own colors.

| Token | Value | Role | Source |
|---|---|---|---|
| `--bg` | `#12121c` | page ground | `docs/index.html:13` |
| `--panel` | `#1e1e30` | card / panel surface | `docs/index.html:15` |
| `--panel2` | `#242438` | inset surface, inline code | `docs/index.html:16` |
| `--ink` | `#e8e6f0` | body text | `docs/index.html:17` |
| `--muted` | `#9a97ad` | secondary text | `docs/index.html:18` |
| `--line` | `#34324a` | 2px borders | `docs/index.html:19` |
| `--accent` | `#8ce99a` | working green, the one accent | `docs/index.html:20` |
| `--input` | `#ff6b6b` | needs-input red | `docs/index.html:21` |
| `--ready` | `#ffd166` | ready yellow | `docs/index.html:22` |
| `--stalled` | `#d4a373` | stalled amber | `docs/index.html:23` |
| `--link` | `#9ecbff` | links | `docs/index.html:24` |

The app carries the same four state colors in `native/src/Config.swift:42-48`
(`cAccent`, `cInput`, `cWarn`, `cStalled`, the last commented "desaturated
amber"), so the page's status colors are the product's status colors.

Rule the page adds: the state colors are reserved for state. Green, red,
yellow and amber appear only where they name a real session phase; everything
else is ink, muted, line and panel. Green is the single accent.

Contrast, measured with the antislop contrast checker:

- `#e8e6f0` on `#12121c` = 15.06:1
- `#9a97ad` on `#12121c` = 6.56:1, on `#1e1e30` = 5.77:1, on `#242438` = 5.35:1
- `#8ce99a` on `#12121c` = 12.61:1
- `#9ecbff` on `#12121c` = 11.02:1
- `#ffd166` on `#1e1e30` = 11.35:1, `#ff6b6b` = 5.9:1, `#d4a373` = 7.23:1
- `#10241a` on `#8ce99a` (primary button) = 11.04:1
- Rejected: `#6d6a85` on `#0d0d15` = 3.73:1, the old code-comment color, which
  fails AA for normal text (`docs/index.html:165`). Replaced with `#9a95b8`
  = 6.78:1. `#6d6a85` survives only as the sleeping swatch on `#1e1e30`
  (3.16:1), where it is a block of color and never text.

Theme: dark only, no toggle. The reason is in the product, not in fashion: the
pet's own window chrome is dark (`cBG` = rgb(0.12, 0.12, 0.16),
`native/src/Config.swift:42`, the same value as `--bg`), and the page shows
sprites and status colors that are only true against that ground.

## Typography

- Stacks kept as they are: system sans (`-apple-system, BlinkMacSystemFont,
  "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif`) and system
  mono (`ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace`).
  Source: `docs/index.html:25-26`. No web fonts, because the page ships as a
  single self-contained file with no external dependencies.
- Mono is for identifiers, not for atmosphere. The app states the rule
  directly: "Menlo only for identifiers: badge, age, path, token counts"
  (`native/src/Panel.swift:47`), with system semibold for titles
  (`native/src/Panel.swift:58`). The page follows it: mono for commands,
  flags, paths, file names, state keys, phase names and the wordmark; system
  sans for headings and prose.
- Pixel sprites use `image-rendering: pixelated` with `shape-rendering:
  crispEdges`, so they stay hard-edged at any size. Source:
  `docs/index.html:91`, `docs/index.html:235`.

## Mood

- Hard-edged, not soft. The existing chrome is a 2px border, 2px radius and a
  4px offset opaque shadow with no blur, which reads as a pixel-era window
  rather than a floating card. Source: `docs/index.html:47-52`. This is the
  identity motif and it repeats on every surface: cards, code blocks, tab
  panels, FAQ rows.
- Small radius everywhere (2px), never pill shapes. Source:
  `docs/index.html:50, 73, 112, 118`.
- The page is a reference document. Density is allowed: tables of flags,
  state keys and env vars are the content, not filler.

## Dial

`Dial: ENERGY 2 / RHYTHM 2 / MOTION 1`

Derived, not chosen, and awaiting the owner's confirmation:

- ENERGY 2: the product is a hopping cartoon pet (playful), documented in
  prose that refuses to oversell (`README.md:92-105`). Neither GOV.UK flat nor
  portfolio loud.
- RHYTHM 2: the content genuinely differs section to section (a phase legend,
  a platform-split install, flag tables, a JSON fragment, an FAQ), so
  composition varies, on one consistent frame.
- MOTION 1: interaction states only. No scroll reveals, no parallax, no
  ambient loops. One exception, and it is the product's own behavior rather
  than decoration: the phase demo animates the sprite while a phase is
  selected by the reader, because "the pet bounces while agents work" and
  "keeps a small reminder hop going until you acknowledge it" are the signals
  the page has to document (`README.md:3-8`, `README.md:59-62`). It is
  user-triggered, it stops, and `prefers-reduced-motion` replaces it with a
  static sprite.

## Constraints

- Single self-contained `docs/index.html`: inline CSS and JS, inline SVG, no
  CDN, no build step. This is how the page is built today
  (`docs/index.html:11-217`) and how it stays.
- Sprites on the page must come from `native/assets.json` pixel maps, which
  the page already claims as its source (`docs/index.html:568-569`). Do not
  draw new art.
- No invented numbers, versions, platforms or endorsements. Every factual
  claim on the page must be traceable to the repo, a git tag, a release, or a
  measured run.
- WCAG AA: 4.5:1 normal text, 3:1 large text and state swatches.
- Mobile: no horizontal overflow, 44px minimum tap targets. The page already
  carries a 560px breakpoint (`docs/index.html:212-216`).
- Every interactive element works with a keyboard and shows a visible focus
  ring.

## Open

Questions the repo does not answer. They are left unanswered on the page
rather than guessed:

1. Is dark-only correct, or does the owner want a light theme for the docs
   site? The app is dark; nothing in the repo states a preference for the
   website.
2. Should the page name a supported version and update it per release, or stay
   version-less? Tags `v0.1.0` (2026-07-27) and `v0.1.1` (2026-08-14) exist
   and the page currently names none.
3. The count "33 intermediate end_turns in a single session" appears only as a
   comment in `native/src/Scanner.swift:326-329`. It is the owner's own
   measurement, with no artifact behind it. Keep it on the page attributed to
   that comment, or drop the number and keep the mechanism?
4. Are `agumon`/`greymon`, `pudge` and `mario` (species in
   `native/assets.json`, added in commits `e409bc7`, `5300434`, `c873f87`)
   meant to be listed publicly on the site, given they are recognizable
   characters from other properties?
5. `pet_window.py` and `pet.py` are marked deprecated/legacy
   (`CUSTOMIZING.md:80, 100-101`). Should the site document the statusline pet at
   all, or only the native pets?
6. Is there a support or contact route (issues only, email, elsewhere)? The
   page has no contact affordance today and none was invented.
