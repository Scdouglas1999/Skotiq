import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';

import '../utils/confirm_dialog.dart';

/// Where a GoTo target sits against the ground and the site's altitude floor.
enum GoToAltitudeKind { clear, belowHorizon, belowFloor }

/// The answer of [judgeGoToAltitude].
class GoToAltitudeVerdict {
  final GoToAltitudeKind kind;
  final double altitudeDeg;
  final double azimuthDeg;

  /// The site's altitude floor toward [azimuthDeg].
  final double floorDeg;

  const GoToAltitudeVerdict({
    required this.kind,
    required this.altitudeDeg,
    required this.azimuthDeg,
    required this.floorDeg,
  });
}

/// Judges a GoTo to [raHours]/[decDeg] at [atUtc] from [site].
///
/// It uses the same alt/az model the scheduler uses to decide what is worth
/// imaging, so the GoTo check and the planner never disagree about where a
/// target is. A site cannot opt out of the ground: below 0 degrees is
/// [GoToAltitudeKind.belowHorizon] whatever the floor says.
GoToAltitudeVerdict judgeGoToAltitude({
  required double raHours,
  required double decDeg,
  required LocationSettings site,
  required AltitudeFloor floor,
  required DateTime atUtc,
}) {
  final (altitudeDeg, azimuthDeg) = AstronomyCalculations.objectAltAz(
    raDeg: raHours * 15.0,
    decDeg: decDeg,
    dt: atUtc,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );
  final floorDeg = floor.atAzimuth(azimuthDeg);
  final kind = altitudeDeg < 0
      ? GoToAltitudeKind.belowHorizon
      : altitudeDeg < floorDeg
          ? GoToAltitudeKind.belowFloor
          : GoToAltitudeKind.clear;
  return GoToAltitudeVerdict(
    kind: kind,
    altitudeDeg: altitudeDeg,
    azimuthDeg: azimuthDeg,
    floorDeg: floorDeg,
  );
}

/// A GoTo the operator is asked about: where its target sits against the
/// ground and the site's floor.
class GoToAltitudeQuestion {
  final GoToAltitudeVerdict verdict;
  final String? targetName;

  /// The floor follows the site's horizon mask rather than one minimum
  /// altitude.
  final bool floorFollowsHorizon;

  const GoToAltitudeQuestion({
    required this.verdict,
    required this.floorFollowsHorizon,
    this.targetName,
  });
}

/// Asks the operator whether a GoTo below the horizon or the site's altitude
/// floor should go ahead. The app's startup gives it the dialog
/// ([askGoToAltitudeOn]); a process with no screen to ask on answers no.
final goToAltitudeAskProvider =
    Provider<Future<bool> Function(GoToAltitudeQuestion question)>(
  (ref) => (_) async => false,
);

/// The question of [goToAltitudeAskProvider], asked on [context]. Completes
/// with true when the GoTo may go.
Future<bool> askGoToAltitudeOn(
  BuildContext context,
  GoToAltitudeQuestion question,
) {
  final verdict = question.verdict;
  final target = question.targetName ?? 'That target';
  final where = 'azimuth ${verdict.azimuthDeg.toStringAsFixed(0)}°';

  if (verdict.kind == GoToAltitudeKind.belowHorizon) {
    return ConfirmDialog.show(
      context: context,
      title: 'Target is below the horizon',
      message: '$target is ${(-verdict.altitudeDeg).toStringAsFixed(1)}° '
          'below the horizon right now ($where): it is under the ground. '
          'Slewing there can drive the telescope into the pier, a tripod leg '
          'or the ground. Check the coordinates, and check your site in '
          'Settings > Location.',
      confirmLabel: 'Slew anyway',
      isDestructive: true,
    );
  }

  return ConfirmDialog.show(
    context: context,
    title: 'Target is below your horizon limit',
    message: '$target is only ${verdict.altitudeDeg.toStringAsFixed(1)}° '
        'above the horizon ($where), under the site\'s '
        '${verdict.floorDeg.toStringAsFixed(0)}° '
        '${question.floorFollowsHorizon ? 'horizon there (Settings > Location)' : 'minimum altitude'}. '
        'It may be behind trees or a roof, and it will be looking through '
        'a lot of air.',
    confirmLabel: 'Slew anyway',
  );
}
