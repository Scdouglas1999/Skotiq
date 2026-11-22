import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../utils/confirm_dialog.dart';
import '../utils/snackbar_helper.dart';

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

/// Asks the operator before a GoTo to a target under the ground or under the
/// site's altitude floor. Completes with true when the GoTo may go.
///
/// No configured site means there is no altitude to judge. A settings-load
/// failure blocks the GoTo because it cannot be told apart from a hidden
/// configured site.
Future<bool> confirmGoToAltitude(
  BuildContext context,
  WidgetRef ref, {
  required double raHours,
  required double decDeg,
  String? targetName,
}) async {
  try {
    await ref.read(appSettingsProvider.future);
  } catch (error) {
    if (context.mounted) {
      context.showErrorSnackBar(
        'Unable to verify target altitude because settings could not be '
        'loaded. Slew was not sent.',
      );
    }
    return false;
  }
  if (!context.mounted) return false;

  // Whether a site exists at all is [appObserverLocationProvider]'s call:
  // (0, 0) is a real place and only that provider decides it means "unset".
  final site = ref.read(appObserverLocationProvider);
  if (site == null) return true;

  final floor = ref.read(altitudeFloorProvider);
  final verdict = judgeGoToAltitude(
    raHours: raHours,
    decDeg: decDeg,
    site: site,
    floor: floor,
    atUtc: DateTime.now().toUtc(),
  );
  if (verdict.kind == GoToAltitudeKind.clear) return true;

  final target = targetName ?? 'That target';
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
        '${floor.followsHorizon ? 'horizon there (Settings > Location)' : 'minimum altitude'}. '
        'It may be behind trees or a roof, and it will be looking through '
        'a lot of air.',
    confirmLabel: 'Slew anyway',
  );
}
