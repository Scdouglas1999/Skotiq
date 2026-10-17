/// The on-ramp ladder that walks a hobbyist from "I take pretty pictures" to
/// "I contribute real measurements." Five rungs in order, each gated on the
/// one before it, so the next thing to do is always the only thing lit up.
///
/// This file is pure data and logic — no widgets, no providers — so the rules
/// can be unit-tested and the UI can stay dumb. The voice across [kScienceLadder]
/// is the same knowledgeable friend at the eyepiece used elsewhere in the app:
/// specific, calm, and quietly encouraging.
library;

enum ScienceRung { measure, track, curve, period, contribute }

enum RungState { locked, ready, done }

class ScienceRungSpec {
  final ScienceRung rung;
  final String title;
  final String blurb;
  final String ctaLabel;

  const ScienceRungSpec({
    required this.rung,
    required this.title,
    required this.blurb,
    required this.ctaLabel,
  });
}

const List<ScienceRungSpec> kScienceLadder = <ScienceRungSpec>[
  ScienceRungSpec(
    rung: ScienceRung.measure,
    title: 'Measure your sky',
    blurb: "Calibrate against real stars and your rig stops guessing — every "
        "brightness it reports from here is a number you can stand behind.",
    ctaLabel: 'Run calibration',
  ),
  ScienceRungSpec(
    rung: ScienceRung.track,
    title: 'Track a star',
    blurb: "Point at a target and let the photometry follow it frame to frame. "
        "Watching one star's brightness live is where the science starts to "
        "feel real.",
    ctaLabel: 'Pick a target',
  ),
  ScienceRungSpec(
    rung: ScienceRung.curve,
    title: 'Build a light curve',
    blurb:
        "Stack up enough measurements and the dots become a shape. Ten points "
        "is plenty to start seeing whether your star is steady, fading, or up "
        "to something.",
    ctaLabel: 'Keep capturing',
  ),
  ScienceRungSpec(
    rung: ScienceRung.period,
    title: 'Find the period',
    blurb: "If that curve repeats, there's a clock hiding in it — an orbit, a "
        "rotation, a pulsation. Let the analysis fold your points and tell you "
        "how long the cycle runs.",
    ctaLabel: 'Analyse the period',
  ),
  ScienceRungSpec(
    rung: ScienceRung.contribute,
    title: 'Contribute it',
    blurb:
        "Your measurements are good enough to share. Export them for the AAVSO "
        "or the MPC and your night becomes part of someone else's research.",
    ctaLabel: 'Export data',
  ),
];

class ScienceLadderProgress {
  final Map<ScienceRung, RungState> states;

  const ScienceLadderProgress(this.states);

  ScienceRung? get nextActionable {
    for (final rung in ScienceRung.values) {
      if (states[rung] == RungState.ready) return rung;
    }
    return null;
  }

  int get doneCount => states.values.where((s) => s == RungState.done).length;
}

ScienceLadderProgress evaluateLadder({
  required bool hasCalibration,
  required bool hasTarget,
  required bool photometryLive,
  required int lightCurvePoints,
  required bool hasPeriodResult,
  required bool hasExportableData,
}) {
  // Each rung is judged on its OWN evidence, never cascaded from the rung
  // above it: a rung is `locked` only when the thing it asks for genuinely
  // cannot be started yet.
  final measure = hasCalibration ? RungState.done : RungState.ready;

  // Points on a curve are proof the star was tracked, whether or not the run
  // that produced them is still going. Picking a target needs nothing first, so
  // this rung is never locked.
  final track = (lightCurvePoints > 0 || (photometryLive && hasTarget))
      ? RungState.done
      : RungState.ready;

  final RungState curve;
  if (lightCurvePoints >= 10) {
    curve = RungState.done;
  } else if (photometryLive || lightCurvePoints > 0) {
    curve = RungState.ready;
  } else {
    curve = RungState.locked;
  }

  final RungState period;
  if (hasPeriodResult) {
    period = RungState.done;
  } else if (lightCurvePoints >= 10) {
    period = RungState.ready;
  } else {
    period = RungState.locked;
  }

  final contribute = hasExportableData ? RungState.ready : RungState.locked;

  return ScienceLadderProgress(<ScienceRung, RungState>{
    ScienceRung.measure: measure,
    ScienceRung.track: track,
    ScienceRung.curve: curve,
    ScienceRung.period: period,
    ScienceRung.contribute: contribute,
  });
}
