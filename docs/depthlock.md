# DepthLock

Mark the detail you care about. Skotiq keeps track of what it still needs.

DepthLock turns "is that faint tail deep enough yet?" into something the
software answers with a number instead of a squint at a stretched preview. You
draw a box over the structure and a second box over nearby blank sky, pick how
deep you want to get, and Skotiq measures that patch on every matching
exposure from then on — across nights, across sessions.

A goal is one filter, on one target, with one setup. If you want L and Ha both
tracked, that is two goals.

## What it is for

**Done is defined by the data, not by the clock.** "Six hours on Ha" is a
budget, not an answer — six hours under a bright moon and six hours on a
transparent night are not the same data. A goal finishes when the structure you
marked actually reaches the depth you asked for, however many nights that takes.

**It allocates clear sky between filters.** Once each filter's goal can say what
it still needs, the panel can put them side by side — *Ha · done · OIII · 3.4 h ·
SII · 1.1 h* — and you can spend tonight on the one that is behind instead of
rotating out of habit. A Smart Exposure plan can take those numbers directly.

**It is a ledger across nights.** The measurement spans sessions, so a target you
come back to in three weeks resumes where it stopped rather than starting from
your memory of it.

**And it gives the negative answer.** Sometimes more hours will not fix it: the
calibration error floor caps how deep the region can go, and no amount of
integration moves a floor. DepthLock says so, names the ceiling, and names the
two things that would actually help. That answer is worth as much as the
positive one — it is the difference between a target that needs another night
and one that needs better flats.

---

## Marking a region

1. Open **Imaging** and display a single, plate-solved, monochrome sub through
   the filter you care about — or switch to the **Live stack** tab and mark on
   the stacked image (see below).
2. Press **Mark region** in the viewer toolbar, or **Mark a region** in the
   DepthLock panel on the right.
3. **Drag the first box** over the faint structure.
4. **Drag the second box** over nearby blank sky. It must not overlap the first
   one, and it should be close enough to share the same sky background.
5. **Adjust either box**: drag a corner or an edge to resize it, drag inside it
   to move it. The boxes stay attached to the frame through pan and zoom.
6. Press **Enter**, or **Use these**, to open the editor. **Escape**, or
   **Cancel**, throws both boxes away.

If the frame on screen cannot anchor a region, the panel says so in one line
and says what to do instead: plate-solve the sub, open a mono sub instead of a
colour render, or save the preview to disk first.

### Marking on the live stack

You can mark a region on the **stacked image**, which is usually where a faint
structure first becomes visible at all. Open the **Live stack** tab: the stack
is a full canvas there, pannable and zoomable, with the stacking controls
beside it. Press **Mark region** on its toolbar and drag the two boxes exactly
as you would on a sub.

This works because the stacker warps every frame into its reference sub's pixel
grid — a box drawn on the stacked image *is* a box in that sub's pixels. The
goal is therefore anchored to the reference sub, never to the stack: the stack
is a composite with no header and no calibration of its own, and could not be
re-measured on a later night.

DepthLock checks the conditions that make this true and says so plainly when
one fails:

- the stacker is not running, or has produced no image yet;
- the stack was started from live frames rather than a file, so it has no
  reference sub;
- the reference sub is not monochrome;
- **the stack and its reference sub are different sizes** — then a box drawn on
  the stack would not land on the reference frame, and marking is blocked
  outright rather than silently anchored to the wrong pixels.

Saved goals are drawn over the stack too, as long as Skotiq has a plate
solve on record for the reference sub. Without one you can still mark a region
— the conversion uses the file's own header — but nothing is drawn over the
stack until the sub is solved, and the toolbar says so.

A region marked on an ordinary sub belongs to that sub's pixels, so that sub
becomes the goal's reference. Either way the panel shows which frame a goal
will be anchored to before you commit.

### The goal editor

Two questions are on the front of the form — **how deep**, and **is the
calibration right** — and everything that follows from them is behind
**Advanced**.

**How deep** is a choice of three presets:

| Preset | Aperture | Depth | For |
| --- | --- | --- | --- |
| Faint | 10″ | 5 | Wisps you can already glimpse in a stretched sub. |
| Very faint | 20″ | 4 | Structure that is hinted at but not yet believable. |
| Extreme | 40″ | 3 | Integrated light that takes many nights to reach. |

The two numbers move together for a physical reason: a wider aperture averages
more sky per measurement, which is what reaches a fainter surface brightness,
and the signal that survives out there is weaker. A preset is a starting point
— Advanced exposes both numbers, and the native validator has the final word on
either. On a very long or very short focal length a preset's aperture is pulled
inside the sampler's 4–64 native-pixel window, and the editor shows the pixel
size it settled on.

A coarser preset needs a bigger region: at least 16 whole apertures must fit
inside the box, and at most 256. The editor states the aperture count live and
repeats the engine's own refusal when the geometry does not work.

**Calibration** shows the master dark and master flat your calibration library
matched for this sub, described by what went into them — "20 × 120 s · −10 °C ·
matched to this sub" — with the path on hover and a **Change…** action. If the
library has no match, the picker appears inline with the reason.

**The error floor is derived, not typed.** Once both masters are chosen,
Skotiq measures the calibration error floor from them at the chosen
aperture and shows it as one line: *Error floor 0.42 ADU — from your masters*.
**Show working** opens the derivation — dark noise, flat noise, sky level and
the aperture it was computed for — and the sentence describing it is stored with
the goal as the floor's source. Advanced lets you override the number, which
the line then reports as yours with the derived value beside it, and a **Use
suggested** action puts it back. If the floor cannot be derived, the editor says
why, opens Advanced, and requires a floor and a source before it will save.

Advanced also carries the square size, the signal-to-noise target, the coverage
requirement (90% by default), the temperature tolerance, and a summary of the
reference frame and the acquisition every contributing light must match.

Only exposures **started after the goal is created** count. The frame you drew
the region on is discovery data: it is what made you look, so it cannot also be
the evidence that you were right.

### Changing a region later

**Edit region** on a goal reopens the tool with that goal's boxes projected onto
the frame currently on screen. Adjust them and commit, and the goal is saved as
a new revision — with the usual warning, because a revision archives the
evidence and starts the measurement over. The goal is re-anchored to the frame
you adjusted it on, so its stored geometry and the frame it names always
describe the same sub.

---

## What the numbers mean

**Signal-to-noise (the "score")** — for each measuring square in your
region, the structure's light above the local sky divided by the noise in that
measurement; the goal uses the *lower quartile* of those, so it describes the
fainter majority of the area you marked, at the square size you chose. It is
the same kind of number you already use for a star: 3 means "there is
something there", 5 is clearly present, 10 is clean, smooth structure. A
bright star in one corner cannot carry it. It grows with the square root of
the exposures — doubling it needs about four times the integration — which
is what makes it a target you can plan against.

**Conservative score** — the score minus a margin that grows with how many
times the goal has been looked at. **This is the number compared against your
threshold**, not the raw score. Checking a growing stack over and over is many
chances to cross a line by luck; the margin is what pays for those chances.

**Uncertainty** — the median per-square uncertainty, in ADU. It is a summary of
how noisy the individual measurements are. It is *not* an error bar on the
score.

**Coverage** — how many of the region's squares were measurable, shown as a
count ("15 of 16 apertures"). Squares that are saturated, masked, or not
covered by every contributing exposure count against coverage rather than
quietly leaving the calculation.

**Evidence / Confirming / Candidate** — how many exposures are in the
measurement, how many arrived after a provisional crossing, and how many are
frozen in that provisional candidate.

### States

| State | What it means |
| --- | --- |
| **Waiting** | Collecting the first 32 exposures. Nothing is measured until then. |
| **Measuring** | Measuring. The goal is not reached yet. |
| **Confirming** | Provisionally reached; waiting for 16 later exposures to confirm. |
| **Achieved** | Reached and confirmed on this revision. |
| **Unreliable** | The measurement is not trustworthy right now. |

Every goal carries one progress element. While it is **Waiting** the bar counts
exposures towards the 32 the estimator needs; once it is measuring, the bar is
the **conservative score against the threshold**, with both numbers written
beside it. A **Confirming** goal also says how far through its confirmation
window it is — "12 of 16 confirming exposures".

There is deliberately no estimate of how long a goal will take. That depends on
the sky, the target's altitude and how many nights you give it, and a number
there would be a guess wearing a countdown's clothes.

`Unreliable` describes the *evidence*, not the goal: a sky gradient across the
background box or a run of correlated residuals will produce it, and cleaner
data can move it back. An unreliable goal never completes a plan.

Each goal also carries the host's own sentence about why the newest frame was
refused — a temperature outside tolerance, a mismatched gain, an unreadable
file. It is repeated verbatim, because it is the only explanation there is.

---

## What it still needs

Once a goal has passed its first 32 exposures it carries a **forecast**: the
same noise model that produces the score, run forward.

- While measuring: *"About 2.4 h more (18 exposures) at the recent sky, then 16
  to confirm."*
- While confirming: *"Confirming — 7 more exposures."*
- When the floor caps it: *"Cannot reach 5.0 at 10″ — the calibration floor caps
  it at 4.1. Larger squares or better flats would help."*

**The forecast assumes the sky stays as it has been.** It is a projection, never
a promise, and that is why it is always quoted "at the recent sky" and always in
integration time rather than as a finishing time. How many hours a goal needs is
a property of the data; which night those hours land on is weather, and
Skotiq does not pretend to know it. You will never see a clock time or a
completion date here.

### The floor limit

`reachable = false` means the calibration error floor — the part of the noise
that does **not** average away with more exposures — holds the score below your
threshold no matter how long you integrate. The **ceiling** is where it stops.

Only two things move it:

- **Larger squares.** A wider aperture averages more sky per measurement and
  reaches a fainter surface brightness. Try the next preset up.
- **Better flats.** The floor is your calibration's own error. Better masters
  lower it. (The editor derives the floor from your masters, so improving them
  and revising the goal changes the answer.)

More hours is not on that list. This is the one case where DepthLock tells you
to stop.

### Tonight's yield

When the newest exposures are noticeably noisier than the best stretch the goal
has seen, a line says so: *"Tonight's exposures are worth about 0.6× your best —
sky is noisier (moon, haze)."* It compares the background scatter of the newest
exposures against the quietest run the goal has recorded, as a variance ratio —
so 0.5 means two of tonight's frames do the work of one good one. Above 0.85 the
difference is within the ordinary night-to-night wobble and nothing is said.

The per-exposure noise numbers behind it — noise per exposure, recent exposures,
best stretch, all in ADU per cell — are in the goal's detail view.

### The progress curve

The goal's detail view plots signal-to-noise against integration time: the
**conservative score** (the one that must clear the threshold) as the solid
line, the **raw score** it comes from as a lighter one, with a horizontal rule
at your goal. Solid segments are measured; dashed segments are the projection.
When a goal is capped, a second dashed rule marks the **floor limit**.

Hovering or tapping the plot puts a crosshair on the nearest point and shows its
integration time, exposure count and both scores. A **Table** toggle shows the
same points as rows. Before the first 32 exposures there is no curve — only a
sentence saying so, because a curve through fewer points would be a picture of a
number that does not exist yet.

## Planning from goals

In a **Smart Exposure** node, once a filter row is bound to a goal, **Plan counts
from goals** writes each bound row's count from what its goal still
expects:

| Situation | What it does |
| --- | --- |
| Reachable forecast | Sets the count to the exposures still needed, confirmation window included. |
| Goal already achieved | Sets the count to 0 and says so. |
| Floor-limited goal | Leaves the row alone — more exposures would not help — and names the cap. |
| Binding is stale (the goal was revised) | Leaves the row alone and asks you to rebind; that forecast belongs to different evidence. |
| Row not bound to a goal | Untouched. It is your plan. |

It writes once and tells you exactly what it set. It is not a live binding: a
count that moved by itself between one look at the sequence and the next would
be a plan nobody authored.

In **loop-until-stopped** mode the per-row counts are ignored anyway, and a
bound goal becomes the thing that ends the filter — the row keeps going until
the goal is reached or the target's window closes.

## Automatic completion

A DepthLock goal can be bound to a filter row of a **Smart Exposure** node. In
the sequencer's properties pane, each filter that has a goal gains a
**Depth goal** dropdown. Choosing one stores the goal's id *and its current
revision*.

When the bound goal is achieved, that filter's plan finishes early and the run
moves on.

The limits:

- **Automation is off by default.** A new goal is advisory until you turn on
  **Automatic completion** on the goal itself. A plan bound to a goal with
  automation off says so, and runs to its count.
- **Depth can only end a plan early, never extend one.** If the plan's count,
  its time budget, the target's visibility, a pause, a safety condition or a
  cancellation arrives first, the run ends as authored and the goal stays open
  for the next session.
- **Unreliable measurements never complete anything.**
- **Editing a goal starts its evidence over.** A revision is a new definition:
  the previous revision is archived, the exposures collected for it stop
  counting, and the measurement begins again. A plan bound to the old revision
  is stale — the editor shows a *Goal was edited; rebind* note with a one-press
  fix, and until you rebind, the plan runs to its count.
- Turning **Collect evidence** or **Automatic completion** on or off is *not* a
  revision: those are preferences, and they leave the evidence alone.

---

## Supported regime

DepthLock refuses what it cannot measure honestly rather than returning a
number anyway. It needs:

- **Monochrome, linear, 16-bit data.** Not a colour render, not a stretched
  preview.
- **Skotiq-format calibration masters** — `FRAMETYP=MASTER`, a flat
  normalised to unit mean, and at least 8 frames behind each master. The
  presentation-oriented clipping calibration used for previews cannot be used
  here, because it discards the signed values the measurement depends on.
- **A plate-solved reference** with an undistorted TAN solution and
  approximately square, orthogonal pixels. SIP distortion is not supported.
- **One setup per goal**: the same camera, filter, exposure, gain, offset and
  binning, with sensor temperature inside the goal's tolerance. Frames that do
  not match are refused, with the reason recorded.
- **A local, roughly flat sky background** near the region. The background box
  is checked for gradients, and a region whose background is not behaving is
  reported unreliable.
- A region within ±85° declination, at most a degree across, yielding 16 to 256
  measuring squares, with the background box disjoint from it and nearby.

---

## What DepthLock is not

- **Not aesthetic judgement.** It says nothing about whether the image looks
  good, whether the stretch is right, or whether the field is worth more time
  for any reason other than depth at the scale you asked for.
- **Not detection.** It does not find anything. It measures a patch you chose,
  and it cannot tell a real faint structure from a calibration residual shaped
  like one. That is what the error floor is for, and the error floor is a
  number *you* supply.
- **Not global image quality.** It is not SNR of the frame, not star quality,
  not integration time, and not a substitute for looking at your subs.
- **Not a scientific guarantee.** The repeated-look margin, the confirmation
  requirement and the refusal gates are empirical safeguards built on measured
  scatter. They are not a confidence interval, and no false-completion
  probability is claimed.

---

## Finding your goals

The DepthLock section of the Imaging side panel lists every goal — name,
filter, state and its progress bar — and opens one into a detail view on tap,
with **All goals** to go back. The detail view is where the full numbers and
every action live.

The first time a markable frame is on screen and you have no goals yet,
Skotiq offers the feature once, above the frame. Dismissing it, or taking
it, is remembered.

## Adding frames by hand

**Add frames** on a goal offers saved lights to it one at a time and reports
what became of each: added, already counted, not needed (the revision is
achieved), acquired before the goal was created, or refused with the reason.
Use it to feed a goal frames that were captured while the analysis queue was
saturated — raw saving is never delayed by analysis, so those frames are on
disk and can be offered later.

**Re-measure** re-evaluates a goal over the evidence it already holds. It
recomputes the report; it cannot advance confirmation, because replaying old
frames is not the same as acquiring new ones.

---

See also: [`depthlock-design.md`](depthlock-design.md) for the measurement
definition and the stopping policy in full.
