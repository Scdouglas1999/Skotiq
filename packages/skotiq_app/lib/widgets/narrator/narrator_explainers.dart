/// "Why this matters" explainers for the Night Narrator detail sheet.
///
/// Each entry is keyed by the stable `eventType` a detector emits (see the
/// detector catalog in `docs/night_narrator_design.md`) and holds a short,
/// plain-language paragraph (2–4 sentences). The tone is a knowledgeable
/// friend standing next to you at the eyepiece: specific, calm, and genuinely
/// excited for the discoveries — never a textbook, never an alarm.
///
/// The map is the single source of truth the detail sheet reads from. It
/// intentionally lives in the app layer (not skotiq_core) because it is a
/// pure presentation concern; the core only carries the structured event data.
library;

/// Optional navigation hint for an explainer's action button. A detail sheet
/// uses [route] with GoRouter's `context.push` and labels the button [label].
/// `null` for an event type means "no actionable destination" — the sheet
/// omits the button rather than inventing a target.
class NarratorAction {
  /// GoRouter location, e.g. `/analytics?tab=diagnostics`.
  final String route;

  /// Button label, e.g. "Open Diagnostics".
  final String label;

  const NarratorAction({required this.route, required this.label});
}

/// Plain-language "why this matters" copy per event type. Covers all 19
/// detectors in the v1 catalog. Lookups for an unknown event type return
/// `null`, and the detail sheet simply hides the explainer block.
const Map<String, String> narratorExplainers = <String, String>{
  // Discovery
  'discovery.moving_object':
      "Something in your field moved between frames against the fixed stars — "
          "usually an asteroid, a comet, or a satellite caught mid-pass. The rate "
          "and brightness tell you which. If it's a real minor planet, a short "
          "follow-up set of frames can turn this into a genuine astrometric "
          "contribution.",
  'discovery.lightcurve_event':
      "Your target's brightness has drifted well beyond its usual scatter for "
          "several frames running — not noise, a real change in the star itself. "
          "A steady fade or brightening like this is exactly the signature of an "
          "eclipse, a transit, or a flare. Keep the cadence steady; the shape of "
          "the curve is the science.",
  'discovery.period_found':
      "The photometry you've been gathering now folds onto a clean, repeating "
          "cycle, and the statistics say it's very unlikely to be chance. That "
          "period is a physical clock — an orbit, a rotation, or a pulsation. "
          "It's the kind of result that makes a night's worth of subs worth it.",

  // First light (difference imaging)
  'first_light.transient':
      "A clean, round point of light is sitting in your difference image where "
          "your deep template of this field was empty — and it matches nothing in "
          "the catalog. That's the classic signature of a genuine transient: a "
          "nova, a supernova, or an outburst nobody has logged yet. Re-image to "
          "confirm it's real and not a cosmic-ray hit, then it's worth a report "
          "to AAVSO or the TNS.",
  'first_light.brightening':
      "A source you've imaged before has jumped well above its usual brightness "
          "in this frame's difference image — a real change, not measurement "
          "scatter. Sudden brightening like this is how dwarf-nova outbursts, "
          "stellar flares, and AGN flickers announce themselves. Keep watching "
          "it: the rise and fall is the science.",
  'first_light.mover':
      "An elongated residual streaked across your difference image, and its "
          "shape says it moved between exposures rather than sitting still like a "
          "star. That's almost always a minor planet or a satellite caught "
          "mid-pass. A short follow-up set, timed and measured, can turn a "
          "passing streak into a real astrometric position.",

  // Milestone
  'milestone.limiting_mag':
      "This is how faint your rig is actually reaching tonight, measured from "
          "real stars rather than a spec sheet. Deeper limiting magnitude means "
          "fainter targets are within reach. When this number improves it usually "
          "means transparency, focus, or guiding just got better.",
  'milestone.calibration_locked':
      "Your photometric zero-point has held steady across the last several "
          "frames, which means the sky and your optics are behaving and your "
          "brightness measurements can be trusted. Locked calibration is the "
          "foundation under every light curve and magnitude you'll report from "
          "tonight.",
  'milestone.best_seeing':
      "The atmosphere just handed you your tightest stars of the night — this "
          "frame's FWHM is in the best slice of everything you've captured. These "
          "are the moments worth pointing your sharpest, faintest targets at. "
          "Seeing comes in pockets, so enjoy it while it lasts.",
  'milestone.integration':
      "You've crossed another whole hour of accumulated exposure on this "
          "target and filter. Integration time is the single biggest lever on "
          "signal-to-noise: more hours means smoother backgrounds and fainter "
          "detail surviving the stretch. Steady progress is how deep images get "
          "made.",

  // Conditions
  'conditions.transparency_trend':
      "The sky's clarity has been trending in one direction long enough to be "
          "a real change, not a passing wisp. Improving transparency lets more "
          "starlight through and deepens your frames; declining transparency "
          "quietly eats your faint signal. It's worth knowing which way the night "
          "is heading.",
  'conditions.sky_darkness':
      "Your sky-quality meter shows the background getting measurably darker "
          "as the night settles — light domes fade, the Moon sets, the air "
          "steadies. A darker sky directly extends how faint you can go. This is "
          "the window to chase your most demanding targets.",
  'conditions.clouds_vs_focus':
      "The star count in one filter dropped well below its recent frames. "
          "The Narrator looks at what else changed: falling measured "
          "transparency or reported cloud points at clouds, a darker sky "
          "background points at something blocking the view, and softer stars "
          "under steady measured transparency point at focus. Without "
          "transparency or weather data it only reports what it measured, "
          "because a star-count drop alone cannot tell cloud from focus.",
  'conditions.excellent':
      "Transparency has been excellent and steady for a good stretch — the "
          "kind of clean, dark window that doesn't come every night. This is when "
          "your narrowest filters and faintest objects pay off the most. If "
          "you've been saving a hard target, now is the moment.",

  // Equipment
  'equipment.tilt':
      "Stars toward one side of the frame are consistently softer than the "
          "rest, which points to the sensor sitting slightly out of plane with "
          "the optical axis — sensor tilt. It robs sharpness from part of every "
          "sub and won't fix itself. The Diagnostics screen shows the per-corner "
          "map you'd use to chase it down.",
  'equipment.focus_drift':
      "Frames have been measuring softer than the same filter did right "
          "after the last autofocus, often as the temperature falls and the "
          "tube contracts. Frames that were rejected, off target, or dimmed by "
          "cloud or an obstruction are left out, so this reflects focus. A "
          "quick refocus pulls the stars back to where they belong.",
  'equipment.gradient':
      "A brightness gradient has been sitting on the same edge of your frames "
          "for several subs — typically stray light, a neighbour's window, or a "
          "light-pollution dome leaking in from one direction. It complicates "
          "calibration and flattening later. Worth chasing the source or flagging "
          "the offending frames.",
  'equipment.guiding_degraded':
      "Your guiding RMS has stayed at least half again above its median of "
          "the last 30 minutes for several minutes. Readings taken while a "
          "dither settles, right after guiding starts, or around autofocus and "
          "flips are left out, so this is a real change. Loose guiding bloats "
          "stars and can trip your frame grader into rejecting subs; the guide "
          "graph usually shows whether it is balance, wind, or seeing.",

  // Quality / pipeline
  'quality.clipping':
      "Several frames in a row are clipping — pixels pinned at the bright or "
          "dark rail where real data should be. Clipped highlights burn out star "
          "cores and clipped shadows crush faint structure, and neither comes "
          "back in processing. Easing exposure, gain, or offset usually recovers "
          "the headroom.",
  'quality.reject_burst':
      "Your auto-grader just rejected several consecutive frames for the same "
          "reason, so this isn't one unlucky sub — something changed. The named "
          "cause points straight at the fix, whether that's focus, guiding, or a "
          "passing cloud. Catching a reject burst early saves a chunk of the "
          "night.",
  'quality.solve_drop':
      "Plate solving was working and has now started failing on most recent "
          "frames. Since solving underpins centering, dithering, and meridian "
          "flips, a drop here can quietly derail the automation. It usually traces "
          "to clouds, focus loss, or a sudden star-count collapse.",
  'quality.pipeline_failure':
      "A stage of the science pipeline failed to process a frame, so the "
          "measurements that stage produces are missing for it. One failure is "
          "rarely fatal, but a recurring one means a real problem upstream worth "
          "investigating. The Diagnostics screen has the detail on what broke.",
};

/// Optional action destinations per event type. Only event types with a
/// genuinely reachable, useful destination get an entry; everything else has
/// no button (the detail sheet omits it rather than hack a target).
const Map<String, NarratorAction> narratorActions = <String, NarratorAction>{
  // Discovery → the photometric / period evidence lives on the science tab.
  'discovery.moving_object': NarratorAction(
    route: '/transients',
    label: 'Observing alerts',
  ),
  'discovery.lightcurve_event': NarratorAction(
    route: '/analytics?tab=science',
    label: 'Open science analytics',
  ),
  'discovery.period_found': NarratorAction(
    route: '/analytics?tab=science',
    label: 'Open science analytics',
  ),

  // First Light → the difference-imaging discoveries land on the transients /
  // observing-alerts surface, where they can be confirmed or triaged.
  'first_light.transient': NarratorAction(
    route: '/transients',
    label: 'Observing alerts',
  ),
  'first_light.brightening': NarratorAction(
    route: '/transients',
    label: 'Observing alerts',
  ),
  'first_light.mover': NarratorAction(
    route: '/transients',
    label: 'Observing alerts',
  ),

  // Milestone → calibration / limiting-mag detail is on the science tab.
  'milestone.limiting_mag': NarratorAction(
    route: '/analytics?tab=science',
    label: 'Open science analytics',
  ),
  'milestone.calibration_locked': NarratorAction(
    route: '/analytics?tab=science',
    label: 'Open science analytics',
  ),

  // Equipment → the per-corner / diagnostics maps.
  'equipment.tilt': NarratorAction(
    route: '/analytics?tab=diagnostics',
    label: 'Open diagnostics',
  ),
  'equipment.gradient': NarratorAction(
    route: '/analytics?tab=diagnostics',
    label: 'Open diagnostics',
  ),

  // Quality → the grader thresholds that drive accept/reject.
  'quality.reject_burst': NarratorAction(
    route: '/settings?section=image-grading',
    label: 'Grader settings',
  ),
  'quality.clipping': NarratorAction(
    route: '/settings?section=image-grading',
    label: 'Grader settings',
  ),

  // Pipeline failures → diagnostics.
  'quality.pipeline_failure': NarratorAction(
    route: '/analytics?tab=diagnostics',
    label: 'Open diagnostics',
  ),
};

/// Resolve the "why this matters" explainer for an [eventType], falling back to
/// the longest matching prefix key when the exact type has no entry.
///
/// Some detectors emit a qualified eventType (e.g.
/// `quality.pipeline_failure.<stage>`) while the catalogs above are keyed on
/// the bare family (`quality.pipeline_failure`). Looking up by longest prefix
/// keeps those cards wired without enumerating every stage permutation.
String? narratorExplainerFor(String eventType) =>
    _longestPrefixLookup(narratorExplainers, eventType);

/// Resolve the optional action for an [eventType], with the same
/// longest-prefix fallback as [narratorExplainerFor].
NarratorAction? narratorActionFor(String eventType) =>
    _longestPrefixLookup(narratorActions, eventType);

V? _longestPrefixLookup<V>(Map<String, V> map, String eventType) {
  final exact = map[eventType];
  if (exact != null) return exact;
  String? bestKey;
  for (final key in map.keys) {
    if (eventType == key || eventType.startsWith('$key.')) {
      if (bestKey == null || key.length > bestKey.length) bestKey = key;
    }
  }
  return bestKey == null ? null : map[bestKey];
}
