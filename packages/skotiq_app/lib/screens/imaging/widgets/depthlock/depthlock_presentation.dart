import 'package:flutter/material.dart' show Color;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// How a DepthLock goal reads on screen: the words for each state, the tone
/// that colours its chip, and the numbers rendered with their units.
///
/// Shared by the imaging panel, the on-canvas overlay and the goal editor so a
/// goal cannot be described one way in one place and another way in the next.

/// Exposures a goal needs before the estimator will say anything at all.
///
/// The native confirmation policy's minimum independent population. It is
/// quoted on screen because a goal that says "collecting" with no denominator
/// is indistinguishable from one that is stuck.
const int kDepthLockMinimumEvidenceFrames = 32;

/// Later-acquired exposures a provisional crossing needs before it is
/// confirmed. Also the native policy's number.
const int kDepthLockConfirmationFrames = 16;

/// The short name of [state], as a chip label.
///
/// Five states, five words: an operator glancing at a list has to be able to
/// tell "has not started measuring" from "measuring but not there yet", and
/// calling both of them Collecting hid exactly that difference.
String depthLockStateLabel(DepthLockState state) => switch (state) {
      DepthLockState.insufficientEvidence => 'Waiting',
      DepthLockState.collecting => 'Measuring',
      DepthLockState.confirmationPending => 'Confirming',
      DepthLockState.achieved => 'Achieved',
      DepthLockState.unreliable => 'Unreliable',
    };

/// One plain-language line saying what [state] means for the operator.
///
/// The native report carries its own `reason`, which is shown verbatim
/// alongside this; these captions say what the STATE is, so a goal that has
/// never been analysed still explains itself.
String depthLockStateCaption(DepthLockState state) => switch (state) {
      DepthLockState.insufficientEvidence =>
        'Collecting the first $kDepthLockMinimumEvidenceFrames exposures. '
            'Nothing is measured until then.',
      DepthLockState.collecting => 'Measuring. The goal is not reached yet.',
      DepthLockState.confirmationPending =>
        'Provisionally reached; waiting for $kDepthLockConfirmationFrames later '
            'exposures to confirm.',
      DepthLockState.achieved => 'Reached and confirmed on this revision.',
      DepthLockState.unreliable =>
        'The measurement is not trustworthy right now. This describes the '
            'evidence, not the goal — cleaner data can move it back.',
    };

/// The chip tone for [state].
///
/// `confirmationPending` is deliberately NOT success: a provisional crossing
/// that later frames have not confirmed is not a finished goal, and colouring
/// it green is how an operator stops a filter one night early.
ChipTone depthLockStateTone(DepthLockState state) => switch (state) {
      DepthLockState.insufficientEvidence => ChipTone.neutral,
      DepthLockState.collecting => ChipTone.primary,
      DepthLockState.confirmationPending => ChipTone.warning,
      DepthLockState.achieved => ChipTone.success,
      DepthLockState.unreliable => ChipTone.error,
    };

/// The colour that draws [state]'s rectangles on the preview.
Color depthLockStateColor(DepthLockState state, SkotiqColors colors) =>
    switch (state) {
      DepthLockState.insufficientEvidence => colors.textMuted,
      DepthLockState.collecting => colors.primary,
      DepthLockState.confirmationPending => colors.warning,
      DepthLockState.achieved => colors.success,
      DepthLockState.unreliable => colors.error,
    };

/// How many apertures [measurement]'s region yields.
///
/// Mirrors the native grid: cells are whole squares of `scaleArcsec` on a
/// side, and an incomplete edge strip is not measured. The panel derives the
/// count this way rather than storing it, so a goal read back from the host
/// reports the same number the editor showed when it was created.
int depthLockApertureCount(DepthLockMeasurement measurement) {
  if (measurement.scaleArcsec <= 0) return 0;
  final int columns =
      (measurement.region.widthArcsec / measurement.scaleArcsec).floor();
  final int rows =
      (measurement.region.heightArcsec / measurement.scaleArcsec).floor();
  if (columns <= 0 || rows <= 0) return 0;
  return columns * rows;
}

/// The aperture side in native pixels at [pixelScaleArcsec].
///
/// The native sampler refuses anything outside 4–64 pixels, so the editor
/// shows this beside the scale field: an operator choosing arcseconds has no
/// other way to see they are about to ask for a two-pixel aperture.
double depthLockAperturePixels({
  required double scaleArcsec,
  required double pixelScaleArcsec,
}) {
  if (pixelScaleArcsec <= 0) return 0;
  return scaleArcsec / pixelScaleArcsec;
}

/// Coverage as the count it actually is — "15 of 16 apertures" — rather than
/// a bare fraction.
String depthLockCoverageLabel({
  required double coverage,
  required DepthLockMeasurement measurement,
}) {
  final int total = depthLockApertureCount(measurement);
  if (total <= 0) return 'Region has no whole apertures';
  final int measurable = (coverage * total).round().clamp(0, total);
  return '$measurable of $total apertures';
}

/// A depth score, which is dimensionless and quoted to one decimal.
String depthLockScore(double? score) =>
    score == null ? '—' : score.toStringAsFixed(1);

/// An ADU quantity, labelled.
String depthLockAdu(double? adu) =>
    adu == null ? '—' : '${adu.toStringAsFixed(2)} ADU';

/// What one ingested file did, as a sentence for the operator.
String depthLockIngestSummary(String fileName, DepthLockIngestOutcome outcome) {
  final String verdict = switch (outcome.outcome) {
    'added' => 'added as evidence',
    'duplicate' => 'already counted',
    'alreadyAchieved' => 'not needed — this revision is already achieved',
    'preSelection' => 'acquired before the goal was created, so not counted',
    'rejected' => 'refused',
    _ => outcome.outcome,
  };
  final String reason = outcome.reason == null || outcome.reason!.isEmpty
      ? ''
      : ': ${outcome.reason}';
  return '$fileName — $verdict$reason';
}

/// A calibration master described the way an operator recognises it, rather
/// than by its path.
///
/// What identifies a master is what went into it — how many frames, at what
/// exposure and temperature — so that is what the line says. The path stays
/// available as a tooltip for the times it matters.
String depthLockMasterSummary(CalibrationMasterRecord record) {
  final parts = <String>[];
  final int? frames = record.frameCount;
  final double? exposure = record.exposureSeconds;
  if (record.type == CalibrationMasterType.flat) {
    if (frames != null) parts.add('$frames frames');
    if (record.filter != null && record.filter!.isNotEmpty) {
      parts.add(record.filter!);
    }
    if (record.flatKind != null && record.flatKind!.isNotEmpty) {
      parts.add('${record.flatKind} flat');
    }
  } else {
    if (frames != null && exposure != null) {
      parts.add('$frames × ${_seconds(exposure)}');
    } else if (frames != null) {
      parts.add('$frames frames');
    } else if (exposure != null) {
      parts.add(_seconds(exposure));
    }
    if (record.temperature != null) {
      parts.add('${record.temperature!.toStringAsFixed(0)} °C');
    }
    if (record.gain != null) parts.add('gain ${record.gain}');
  }
  if (record.binX != 1 || record.binY != 1) {
    parts.add('${record.binX}×${record.binY}');
  }
  // A master with no metadata at all is still a master; say so rather than
  // render an empty line.
  return parts.isEmpty ? 'No details recorded' : parts.join(' · ');
}

String _seconds(double value) => value >= 1
    ? '${value.toStringAsFixed(0)} s'
    : '${value.toStringAsFixed(2)} s';

/// The message an error carries, without rewording it.
///
/// A DepthLock refusal is the native engine explaining a geometry, a stale
/// revision or an unusable master to the operator. Anything this layer
/// substituted would be less useful than what it replaced, so the only work
/// done here is unwrapping the envelope the error arrived in.
String depthLockErrorMessage(Object error) {
  if (error is SkotiqError) return error.userMessage;
  // The FFI backend throws the bridge union, whose toString leaks the
  // freezed wrapper around the native reason.
  final bridged = bridgeErrorMessage(error);
  if (bridged != null) return bridged;
  final raw = error.toString();
  return raw.startsWith('Exception: ')
      ? raw.substring('Exception: '.length)
      : raw;
}

/// `2026-09-12 21:40` in the device's own time, for a selection timestamp.
///
/// A goal's selection date is the line between discovery data and evidence, so
/// it is shown to the minute rather than as "3 days ago": the operator matches
/// it against the timestamps on their own subs.
String depthLockTimestamp(int unixMs) {
  final when = DateTime.fromMillisecondsSinceEpoch(unixMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${when.year}-${two(when.month)}-${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}';
}

/// Integration time for [frames] exposures of this goal, in hours.
double depthLockHours({required int frames, required double exposureSecs}) =>
    frames <= 0 || exposureSecs <= 0 ? 0 : frames * exposureSecs / 3600.0;

/// Integration time written the way an observer plans with it.
///
/// Hours to one decimal above one hour, minutes below: "2.4 h", "35 min".
/// Never a clock time or a finish date — the forecast is a quantity of
/// integration, and the night it lands on depends on weather nobody has.
String depthLockDuration(double hours) {
  if (hours <= 0) return '0 min';
  if (hours < 1) return '${(hours * 60).round()} min';
  return '${hours.toStringAsFixed(1)} h';
}

/// What the goal expects still to cost, or null when there is nothing to say.
///
/// Every phrasing that quotes a number also says the assumption it rests on:
/// the forecast is the noise model run forward, and it holds only while the
/// sky stays as it has been.
String? depthLockForecastLine(DepthLockGoal goal) {
  final report = goal.report;
  final measurement = goal.definition.measurement;

  if (goal.state == DepthLockState.insufficientEvidence) {
    final int remaining = kDepthLockMinimumEvidenceFrames - goal.evidenceFrames;
    if (remaining <= 0) return null;
    return '$remaining more exposure${remaining == 1 ? '' : 's'} before '
        'measuring starts.';
  }

  final forecast = report?.forecast;
  if (forecast == null) return null;

  if (!forecast.reachable) {
    // Name the two remedies the model actually supports and nothing else:
    // the floor is what caps the score, so only a coarser aperture or a
    // smaller calibration error moves it. More hours will not.
    return 'Cannot reach ${measurement.threshold.toStringAsFixed(1)} at '
        '${measurement.scaleArcsec.toStringAsFixed(0)}″ — the calibration '
        'floor caps it at ${forecast.ceilingScore.toStringAsFixed(1)}. '
        'Larger squares or better flats would help.';
  }

  if (goal.state == DepthLockState.confirmationPending) {
    final int remaining = forecast.framesToConfirm;
    if (remaining <= 0) return 'Confirming — waiting on the next exposure.';
    return 'Confirming — $remaining more exposure${remaining == 1 ? '' : 's'}.';
  }

  if (goal.state == DepthLockState.achieved) return null;

  final int toThreshold = forecast.framesToThreshold;
  if (toThreshold <= 0) return null;
  final double hours = depthLockHours(
    frames: toThreshold,
    exposureSecs: goal.definition.acquisition.exposureSecs,
  );
  final String confirm = forecast.framesToConfirm > 0
      ? ', then ${forecast.framesToConfirm} to confirm'
      : '';
  return 'About ${depthLockDuration(hours)} more ($toThreshold '
      'exposure${toThreshold == 1 ? '' : 's'}) at the recent sky$confirm.';
}

/// Below this, the newest exposures are worth saying something about.
///
/// Above it the difference is within the night-to-night wobble of any sky and
/// a line about it would be noise of its own.
const double kDepthLockYieldNoticeBelow = 0.85;

/// What tonight's sky is doing to the goal's progress, or null when it is
/// doing nothing worth a line.
String? depthLockYieldLine(DepthLockGoal goal) {
  final forecast = goal.report?.forecast;
  if (forecast == null) return null;
  final double yield = forecast.recentYield;
  if (yield >= kDepthLockYieldNoticeBelow) return null;
  return 'Tonight\'s exposures are worth about '
      '${yield.toStringAsFixed(1)}× your best — sky is noisier (moon, haze).';
}

/// What each filter still owes, for the panel's header.
///
/// One line that answers "where is tonight's clear sky best spent": a filter
/// that is finished says so, one the floor caps says so, and the rest quote
/// the integration time their goals still expect. Null when no goal has a
/// forecast yet, because a header of em dashes says nothing.
String? depthLockAllocationSummary(List<DepthLockGoal> goals) {
  if (goals.isEmpty) return null;
  final order = <String>[];
  final remainingHours = <String, double>{};
  final anyReachable = <String, bool>{};
  final anyCapped = <String, bool>{};
  var sawForecast = false;

  for (final goal in goals) {
    final String filter = goal.definition.filterName;
    if (!order.contains(filter)) order.add(filter);
    final forecast = goal.report?.forecast;
    if (forecast == null) continue;
    sawForecast = true;
    if (!forecast.reachable) {
      anyCapped[filter] = true;
      continue;
    }
    if (goal.state == DepthLockState.achieved) continue;
    anyReachable[filter] = true;
    remainingHours[filter] = (remainingHours[filter] ?? 0) +
        depthLockHours(
          frames: forecast.framesRemaining,
          exposureSecs: goal.definition.acquisition.exposureSecs,
        );
  }
  if (!sawForecast) return null;

  final parts = <String>[];
  for (final filter in order) {
    final String value;
    if (anyReachable[filter] == true) {
      value = depthLockDuration(remainingHours[filter] ?? 0);
    } else if (anyCapped[filter] == true) {
      value = 'floor limit';
    } else {
      value = 'done';
    }
    parts.add('$filter · $value');
  }
  return parts.join(' · ');
}
