/// The wording of a backlash figure, in one place.
///
/// The measurement is only meaningful WITH its position and temperature —
/// 105 steps near 6600 and 83 steps near 2500 came off the same focuser on the
/// same night. Every surface that shows the number therefore builds its
/// sentence here so none of them can drift into printing a bare figure.
library;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// "position 6620, 14.5 °C, on 14 September 2026" — the conditions the figure
/// belongs to, for the wizard's result panel.
String backlashConditions(FocuserBacklashCalibration c) {
  final date = DateFormat('d MMMM yyyy').format(c.takenAt.toLocal());
  final temperature = c.temperatureCelsius;
  if (temperature == null) {
    // Not "unknown": the focuser has no probe to ask. Say which it is, because
    // a backlash figure without a temperature is still usable — it just cannot
    // be compared against a later one taken in different conditions.
    return 'position ${c.measuredAtPosition} on $date. This focuser '
        'reports no temperature, so there is nothing to compare a later '
        'measurement against';
  }
  return 'position ${c.measuredAtPosition} at '
      '${temperature.toStringAsFixed(1)} °C on $date';
}

/// The compact form for a settings sub-line: "measured on 14 Sep 2026 at
/// position 6620".
String backlashRecordSubLine(FocuserBacklashCalibrationRecord record) {
  final date = DateFormat('d MMM yyyy').format(record.measuredAt.toLocal());
  return 'measured on $date at position ${record.measuredAtPosition}';
}

/// The one sentence that matters most about this number: it is local to the
/// place it was taken.
const String backlashVariesNotice =
    'Backlash varies along the travel — this figure belongs to the part of '
    'the range it was measured in. Measure again if you move a long way from '
    'there, or change the gear train.';

String confidenceLabel(FocuserBacklashConfidence confidence) =>
    switch (confidence) {
      FocuserBacklashConfidence.high => 'High confidence',
      FocuserBacklashConfidence.moderate => 'Moderate confidence',
      FocuserBacklashConfidence.low => 'Low confidence',
    };

ChipTone confidenceTone(FocuserBacklashConfidence confidence) =>
    switch (confidence) {
      FocuserBacklashConfidence.high => ChipTone.success,
      FocuserBacklashConfidence.moderate => ChipTone.warning,
      // Not `error`: a low-confidence figure is still a real measurement, and
      // the reason beside it says what would improve it.
      FocuserBacklashConfidence.low => ChipTone.warning,
    };

/// The three families of refusal, which differ in what the operator should do
/// next and therefore in how the panel is toned.
enum BacklashRefusalFamily {
  /// The sky or the frame did not supply enough stars. Nothing to fix in the
  /// setup — try again under better conditions.
  stars,

  /// Enough stars, but the curves would not support a conclusion.
  fit,

  /// The answer fell outside the room the scan or the focuser had. A setup
  /// change is needed before another attempt can succeed.
  range,

  /// The two scans contradict each other: backlash cannot produce a negative
  /// difference, so focus moved between them or the focuser is not reaching
  /// the positions it is sent. Neither the sky nor the scan geometry is the
  /// problem, which is why it is its own family.
  inconsistent,
}

/// Groups one of the nine native refusal codes.
///
/// An unrecognised code groups as [BacklashRefusalFamily.fit] — the neutral
/// "could not conclude" presentation — so a code added natively still renders
/// as a dignified refusal with its own verbatim message and remedy rather than
/// as a crash or a blank panel.
BacklashRefusalFamily refusalFamily(String code) => switch (code) {
      'scan_abandoned_for_stars' ||
      'too_few_stars_at_focus' ||
      'too_few_measurable_points' =>
        BacklashRefusalFamily.stars,
      'not_enough_points' || 'poor_fit' => BacklashRefusalFamily.fit,
      'vertex_outside_scan' ||
      'exceeds_scan_range' ||
      'exceeds_reversal_budget' =>
        BacklashRefusalFamily.range,
      'negative_beyond_resolution' => BacklashRefusalFamily.inconsistent,
      _ => BacklashRefusalFamily.fit,
    };

IconData refusalIcon(String code) => switch (refusalFamily(code)) {
      BacklashRefusalFamily.stars => LucideIcons.starOff,
      BacklashRefusalFamily.fit => LucideIcons.activity,
      BacklashRefusalFamily.range => LucideIcons.ruler,
      BacklashRefusalFamily.inconsistent => LucideIcons.gitCompare,
    };

/// A refusal is never an error: nothing broke, and the app declined to publish
/// a number it could not stand behind. Star and fit refusals are informational
/// (try again); a range or contradictory one is a warning, because something
/// about the setup has to change before a retry can do any better.
BannerTone refusalTone(String code) => switch (refusalFamily(code)) {
      BacklashRefusalFamily.stars => BannerTone.info,
      BacklashRefusalFamily.fit => BannerTone.info,
      BacklashRefusalFamily.range => BannerTone.warning,
      BacklashRefusalFamily.inconsistent => BannerTone.warning,
    };

/// The panel heading above the verbatim [FocuserBacklashRefusal.message].
///
/// Deliberately says only which FAMILY the refusal is in — the native message
/// carries the specifics and is rendered unchanged underneath.
String refusalHeading(String code) => switch (refusalFamily(code)) {
      BacklashRefusalFamily.stars => 'Not enough stars to measure',
      BacklashRefusalFamily.fit => 'The curves do not support a figure',
      BacklashRefusalFamily.range => 'The measurement ran out of room',
      BacklashRefusalFamily.inconsistent => 'The two scans disagree',
    };

/// "about 4 minutes", "about 1 minute 30 seconds", "under a minute".
String describeEstimate(Duration d) {
  if (d.inSeconds < 60) return 'under a minute';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  final minutePart = minutes == 1 ? '1 minute' : '$minutes minutes';
  if (seconds == 0) return 'about $minutePart';
  return 'about $minutePart ${seconds}s';
}
