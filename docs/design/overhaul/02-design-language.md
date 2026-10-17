# 02 · Design language: "Observatory"

Skotiq is an instrument. Not a dashboard, not a website, not a consumer app. The design
language is named after the thing the software replaces: a dark room with quiet, precise readouts,
where the sky is the brightest thing in it.

## The five rules

Every decision in 03–06 follows from these. When a spec is silent, apply the rule.

1. **The sky is the hero.** Any screen that shows imagery (Imaging, Planetarium, Framing, Darkroom,
   Tonight's live preview) gives the image the largest uninterrupted area it can, edge to edge, with
   controls floating over it in glass panels. Chrome never competes with photons.

2. **Tone, not lines.** Depth comes from a four-step tonal ladder (`bg → surface → elevated →
   overlay`), plus a darker `well` for data displays. Borders are for dividers and focused
   controls only. A panel has no visible border: on dark it carries a 1 px ring at 4% white that
   only stops its edge vanishing on a poor monitor; on light it has a 1 px `border` because white
   on off-white has no tone. A panel inside a panel does not exist; the deepest nesting is
   panel → well.

3. **Numbers are loud, labels are quiet.** A readout is a mono value in `readoutMd` (20 px, weight
   500, tabular) or `readoutLg` (28 px) with an 11 px uppercase label beneath it. The label never
   competes. Units are 60% size and muted, attached to the number. Unknown values are shown as an
   em dash in muted colour and never as `---`.

4. **One of everything.** One primary button per page (in the header, the hero, or, when neither
   has one, the detail column) and one per dialog; side panels, lists and rows use secondary or
   ghost. One tab style (underline, in the page
   header). One status surface (the instrument bar). One banner style, and at most one banner per
   problem across the whole app. One empty-state pattern. One dialog anatomy. If a screen needs a
   second style of something, the screen is wrong, not the system.

5. **Say it once, say it where it matters.** No subtitle sentences under page titles. No tour
   toasts. No modal that repeats a banner. Setup problems live in ONE place, the "Ready for first
   light" checklist on Tonight, and each surface that depends on the missing thing shows a single
   inline banner with the same wording and the same action.

## What "expensive" looks like here

- Precise alignment to a 4 px grid, with 8 / 16 / 24 as the working rhythm.
- Generous page gutters (24 px) and tight component internals (8–12 px). Space outside, density
  inside.
- A single accent, used for at most three things: the primary action, the selected state, links.
  Everything else is grey or a status colour.
- Weight contrast instead of size contrast for most hierarchy: 600 for titles, 500 for controls and
  readouts, 400 for prose. Size jumps are reserved for the page hero and readouts.
- Motion that confirms, never decorates: 120 ms hover, 160 ms state change, 220 ms panel
  open/close, all with the same ease-out curve. Nothing pulses except a live indicator dot.
- Empty states that are short, centred, and end in one button.
- Copy in sentence case, in the second person, with numbers in figures. "Connect your camera and
  mount", not "Critical devices".

## What Observatory is not

- Not glassmorphism everywhere. Glass is for HUD chips over imagery only.
- Not gradients on controls. The only gradient in the app is the sky band on Tonight.
- Not rounded-everything. Radii: 4 (chips), 6 (controls, fields, wells), 8 (panels, rail items),
  12 (dialogs, popovers). Nothing else.
- Not a colour-coded rainbow. Status colours mean status. Filters (L/R/G/B/Ha/OIII/SII) may use the
  chart palette in charts and thumbnails, never on chrome.

## Signature moments

These are the four places where the app should make someone say "who designed this?". Build them
exactly as mocked up, they are the most important pixels in the overhaul.

| Moment | Where | Mockup |
|---|---|---|
| **The night band.** A horizontal timeline of tonight (sunset → astro dark → dawn → sunrise) with a sky gradient, the current-time marker, the target's altitude arc and its imageable window. | Tonight, top of the page, always visible | `mockups/png/tonight.png`, `tonight-empty.png` |
| **The hero line.** State eyebrow, then the target or the night's headline at 28 px, then one line of facts, with the ONE primary action on the right. | Tonight | `tonight.png` |
| **Glass HUD over the frame.** Readouts and the capture bar float over the image; the image runs edge to edge under a single 44 px toolbar. | Imaging, Live stack, Darkroom, Framing | `imaging.png` |
| **The checklist.** First-run and "something is missing" state is one numbered checklist with the done items struck through and the next step highlighted. It replaces ten tour toasts and four catalog nags. | Tonight (empty state), Equipment side panel | `tonight-empty.png`, `equipment.png` |

## Vocabulary (use these words in code and docs)

| Term | Meaning |
|---|---|
| **Top bar** | 44 px window bar: brand, global search/command field, global actions, window controls. |
| **Rail** | Left navigation, 64 px icon-only or 220 px with labels. Grouped Observe / Prepare / Review. |
| **Instrument bar** | 32 px bottom status bar. The only persistent status surface. |
| **Page header** | 56 px row inside a screen: title, underline tabs, actions. |
| **Panel** | A `surface`-toned container with 8 px radius and 16 px padding. Replaces "card". |
| **Well** | A `well`-toned inset inside a panel, for charts, images and empty areas. |
| **Readout** | Mono value + uppercase label. |
| **Eyebrow** | 11 px uppercase 600 muted label above a block. |
| **Glass** | Translucent blurred panel used ONLY over imagery. |
| **Side panel** | 320 px right column with a 44 px vertical icon strip for its sections. |
| **Checklist** | The numbered setup list on Tonight. |
