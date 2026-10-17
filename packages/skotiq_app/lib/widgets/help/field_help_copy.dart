/// Centralized, single-source-of-truth help copy for the genuinely
/// non-obvious form controls scattered across the equipment, capture, guiding,
/// and plate-solving UIs.
///
/// This file is pure Dart const data — it imports nothing and depends on no
/// Flutter or design-system code — so it can be unit-tested in isolation and
/// reused by any widget (desktop, mobile, dialogs) that wants to feed
/// [FieldHelpLabel] / `helpAffordance` a consistent `title` + `body` pair.
///
/// Scope is deliberately narrow: only controls whose meaning or correct value
/// is *not* self-evident from the label earn an entry. Obvious fields ("Target
/// name", "Exposure time") are excluded — a help bubble on every control is
/// noise, and noise trains users to ignore the bubbles that matter.
///
/// Wrong help is worse than no help, because the user trusts it. Each [body] is
/// one factual sentence describing what the control does, followed by practical
/// guidance for a typical astrophotography rig.
library;

/// Identifies a single field-level help string.
///
/// Each id appears exactly once in [kFieldHelpCopy]; [helpFor] and the tests
/// enforce that exhaustively, so adding an id without copy is a surfaced error
/// rather than a silent gap.
///
/// Only genuinely non-obvious controls are enumerated here. If you find
/// yourself wanting to add an "obvious" field (a name, a directory, a plain
/// exposure time), don't — the value of these affordances comes from being
/// rare enough that users learn to trust them.
enum FieldHelpId {
  /// CMOS/CCD sensor gain (analog amplification).
  cameraGain,

  /// Black-level pedestal added to every pixel.
  cameraOffset,

  /// Sensor readout / ADC mode (e.g. high-gain vs low-noise).
  cameraReadoutMode,

  /// Pixel binning factor for a capture.
  captureBinning,

  /// Frame type / image classification (light, dark, flat, bias).
  captureFrameType,

  /// Dither distance between exposures, in guide-camera pixels.
  ditherAmount,

  /// Guiding settle accuracy threshold before a capture starts.
  settleThreshold,

  /// Minimum time guiding must stay settled before a capture starts.
  settleTime,

  /// Minimum guide pulse, in milliseconds, the mount will act on.
  guideMinPulse,

  /// How far past the meridian the mount tracks before flipping.
  meridianFlipTrigger,

  /// Tolerances used to match a light frame to a calibration dark.
  darkLibraryMatching,

  /// Sky radius the plate solver searches around the hint coordinates.
  plateSolverSearchRadius,
}

/// A two-part help payload: a short [title] (the term itself) and a one-line
/// [body] (what it does + practical guidance).
///
/// Maps directly onto [FieldHelpLabel.helpTitle] / [FieldHelpLabel.helpBody]
/// and `helpAffordance(title:, body:)`.
class FieldHelpCopy {
  /// The term, shown bold at the top of the rich tooltip — usually the same
  /// word as the field label (e.g. `Gain`).
  final String title;

  /// One factual sentence: what the control does, then how to set it. Kept
  /// short so the tooltip stays tight and readable.
  final String body;

  const FieldHelpCopy({required this.title, required this.body});
}

/// The single source of truth for field-level help copy.
///
/// MUST cover every [FieldHelpId] exactly once — [helpFor] and the tests both
/// enforce this, so adding a new id without copy is a surfaced error rather
/// than a silent gap.
const Map<FieldHelpId, FieldHelpCopy> kFieldHelpCopy =
    <FieldHelpId, FieldHelpCopy>{
  FieldHelpId.cameraGain: FieldHelpCopy(
    title: 'Gain',
    body:
        'Sensor amplification applied before the analog-to-digital conversion. '
        'Higher gain lowers read noise but reduces dynamic range and full-well '
        "depth — use your camera's unity or manufacturer-recommended gain "
        'unless you have a specific reason not to.',
  ),
  FieldHelpId.cameraOffset: FieldHelpCopy(
    title: 'Offset',
    body: 'A constant black-level pedestal added to every pixel so the noise '
        'floor never clips to zero. Set it just high enough that the left edge '
        "of your bias histogram clears zero — your camera's recommended offset "
        'for the chosen gain is almost always correct.',
  ),
  FieldHelpId.cameraReadoutMode: FieldHelpCopy(
    title: 'Readout mode',
    body: 'Selects how the sensor digitizes each frame, trading read noise '
        'against dynamic range and speed. For deep-sky work choose the '
        'low-noise / high-gain mode; reserve high-dynamic-range modes for '
        'bright targets like the Moon and planets.',
  ),
  FieldHelpId.captureBinning: FieldHelpCopy(
    title: 'Binning',
    body:
        'Combines an NxN block of pixels into one, boosting signal-to-noise and '
        'frame rate at the cost of resolution. Most CMOS cameras bin in '
        'software with little gain, so shoot 1x1 for deep-sky and reserve '
        'higher binning for oversampled rigs or focusing.',
  ),
  FieldHelpId.captureFrameType: FieldHelpCopy(
    title: 'Frame type',
    body:
        'Classifies the frame so calibration and stacking treat it correctly: '
        'Light captures the target, while Dark, Flat, and Bias are calibration '
        'frames that remove thermal signal, vignetting, and read offset.',
  ),
  FieldHelpId.ditherAmount: FieldHelpCopy(
    title: 'Dither amount',
    body:
        'How far the mount nudges between exposures, in guide-camera pixels, so '
        'fixed-pattern noise and hot pixels land on different pixels each frame. '
        'A few pixels (typically 3-5) is enough; larger dithers need more '
        'settle time.',
  ),
  FieldHelpId.settleThreshold: FieldHelpCopy(
    title: 'Settle threshold',
    body:
        'The maximum guide error, in pixels, that counts as "settled" after a '
        'dither or slew before the next exposure may start. Tighter values '
        'protect sharpness but can stall on a shaky mount — 1-2 pixels suits '
        'most rigs.',
  ),
  FieldHelpId.settleTime: FieldHelpCopy(
    title: 'Settle time',
    body: 'How long, in seconds, guiding must stay within the settle threshold '
        'before a capture begins. It prevents starting an exposure mid-bounce; '
        '5-10 seconds is typical, longer for heavier or wind-exposed mounts.',
  ),
  FieldHelpId.guideMinPulse: FieldHelpCopy(
    title: 'Min pulse',
    body: 'The shortest guide pulse, in milliseconds, the built-in guider will '
        'issue; corrections that would need a briefer pulse are skipped because '
        'the mount cannot act on them reliably. Keep it within the range your '
        'mount reports — raise it if tiny pulses make guiding jittery, lower it '
        'only if guiding responds too slowly.',
  ),
  FieldHelpId.meridianFlipTrigger: FieldHelpCopy(
    title: 'Flip past meridian',
    body: 'How many minutes past the meridian the mount keeps tracking before '
        'performing a meridian flip. Set it just under your mount\'s safe '
        'tracking limit so it images as long as possible without the optics '
        'striking the pier.',
  ),
  FieldHelpId.darkLibraryMatching: FieldHelpCopy(
    title: 'Dark matching',
    body: 'The tolerances used to pick a stored dark for a light frame — '
        'exposure, gain, offset, binning, and sensor temperature must all fall '
        'within range. Keep them tight (especially temperature and exposure) so '
        'a mismatched dark never over- or under-subtracts.',
  ),
  FieldHelpId.plateSolverSearchRadius: FieldHelpCopy(
    title: 'Search radius',
    body:
        'How far, in degrees, the solver searches around the hint coordinates '
        'for a match. A small radius (a few degrees) solves fastest when '
        'pointing is good; widen it only after a failed solve or a cold start '
        'with no reliable hint.',
  ),
};

/// Returns the help copy for [id].
///
/// Throws a [StateError] if no copy is defined for [id]. [kFieldHelpCopy] is
/// required to be exhaustive over [FieldHelpId], so a missing entry is a
/// programming error that must surface immediately rather than be papered over
/// with a silent fallback. Mirrors the `stepFor` contract in `skotiq_core`'s
/// next-use-steps model.
FieldHelpCopy helpFor(FieldHelpId id) {
  final copy = kFieldHelpCopy[id];
  if (copy == null) {
    throw StateError(
      'No FieldHelpCopy defined for FieldHelpId.${id.name}. '
      'kFieldHelpCopy must cover every FieldHelpId.',
    );
  }
  return copy;
}
