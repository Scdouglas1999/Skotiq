part of '../target_scoring.dart';

/// What an operator should know about a target's night: a low peak, a poor
/// airmass, the Moon, a short window, a late start or an early set.
List<TargetWarning> nightWarnings({
  required double peakAlt,
  required double bestAirmass,
  required double moonDist,
  required double moonIllumination,
  required ObjectVisibility visibility,
  required double hoursAboveMin,
  required DateTime nightStart,
  required DateTime nightEnd,
  DateTime? firstObservableTime,
}) {
  final warnings = <TargetWarning>[];

  // Peak altitude warnings
  if (peakAlt < 0) {
    warnings.add(
      const TargetWarning(
        type: WarningType.belowHorizon,
        severity: WarningSeverity.critical,
        message: 'Below horizon all night',
        suggestion: 'Target is not visible during this night',
      ),
    );
  } else if (peakAlt < 15) {
    warnings.add(
      TargetWarning(
        type: WarningType.lowAltitude,
        severity: WarningSeverity.warning,
        message:
            'Low peak altitude (${peakAlt.toStringAsFixed(0)}°) - poor seeing expected',
        suggestion: 'Consider imaging on a different night',
      ),
    );
  } else if (peakAlt < 30) {
    warnings.add(
      TargetWarning(
        type: WarningType.lowAltitude,
        severity: WarningSeverity.caution,
        message: 'Moderate peak altitude (${peakAlt.toStringAsFixed(0)}°)',
        suggestion: visibility.transitAltitude != null
            ? 'Max altitude: ${visibility.transitAltitude?.toStringAsFixed(0)}°'
            : null,
      ),
    );
  }

  // Airmass (best during the night)
  if (bestAirmass > 2.5 && bestAirmass.isFinite) {
    warnings.add(
      TargetWarning(
        type: WarningType.highAirmass,
        severity: WarningSeverity.warning,
        message:
            'Best airmass ${bestAirmass.toStringAsFixed(2)} - atmospheric extinction',
        suggestion: 'Image quality may be degraded all night',
      ),
    );
  } else if (bestAirmass > 2.0 && bestAirmass.isFinite) {
    warnings.add(
      TargetWarning(
        type: WarningType.highAirmass,
        severity: WarningSeverity.caution,
        message: 'Elevated best airmass (${bestAirmass.toStringAsFixed(2)})',
      ),
    );
  }

  warnings.addAll(_moonProximityWarnings(moonDist, moonIllumination));

  // Short imaging window
  final nightHours = nightEnd.difference(nightStart).inMinutes / 60.0;
  if (hoursAboveMin > 0 && hoursAboveMin < 2.0 && nightHours > 0) {
    warnings.add(
      TargetWarning(
        type: WarningType.settingSoon,
        severity: WarningSeverity.warning,
        message:
            'Short imaging window (${hoursAboveMin.toStringAsFixed(1)} hours)',
        suggestion: 'Limited time above minimum altitude tonight',
      ),
    );
  } else if (hoursAboveMin >= 2.0 && hoursAboveMin < 4.0 && nightHours > 4) {
    warnings.add(
      TargetWarning(
        type: WarningType.settingSoon,
        severity: WarningSeverity.caution,
        message:
            'Moderate imaging window (${hoursAboveMin.toStringAsFixed(1)} hours)',
      ),
    );
  }

  // Becomes usable only late in the night.
  //
  // Read from the first sampled instant above the floor, not the horizon
  // rise time: a target already high at dusk has nothing to warn about, and
  // one that never clears the floor is covered by the warnings above.
  if (firstObservableTime != null && peakAlt >= 0) {
    final nightDuration = nightEnd.difference(nightStart);
    final availableOffset = firstObservableTime.difference(nightStart);
    // If the target only becomes usable in the last third of the night.
    if (nightDuration > Duration.zero &&
        availableOffset > nightDuration * 0.66) {
      warnings.add(
        TargetWarning(
          type: WarningType.notYetRisen,
          severity: WarningSeverity.info,
          // "Usable from", not "Rises at": the threshold crossed here is the
          // configured minimum altitude over the local skyline, which a
          // target can clear hours after it geometrically rises.
          message: 'Usable only from ${ClockFormat.hm(firstObservableTime)}',
          suggestion: 'Target becomes available late in the night',
        ),
      );
    }
  }

  // Sets early in the night
  if (visibility.setTime != null && peakAlt >= 0) {
    final setTime = visibility.setTime!;
    if (setTime.isBefore(nightEnd) && setTime.isAfter(nightStart)) {
      final nightDuration = nightEnd.difference(nightStart);
      final setOffset = setTime.difference(nightStart);
      // If the target sets in the first third of the night
      if (setOffset < nightDuration * 0.33) {
        warnings.add(
          TargetWarning(
            type: WarningType.settingSoon,
            severity: WarningSeverity.caution,
            message: 'Sets early at ${ClockFormat.hm(setTime)}',
            suggestion: 'Image this target early in the session',
          ),
        );
      }
    }
  }

  return warnings;
}

/// Moon-proximity warnings for a target [moonDist] degrees from a Moon
/// [moonIllumination] percent lit.
List<TargetWarning> _moonProximityWarnings(
  double moonDist,
  double moonIllumination,
) {
  if (moonIllumination <= 20) return const [];

  if (moonDist < 15) {
    return [
      TargetWarning(
        type: WarningType.moonProximity,
        severity: WarningSeverity.critical,
        message:
            'Very close to Moon (${moonDist.toStringAsFixed(0)}°) - ${moonIllumination.toStringAsFixed(0)}% illuminated',
        suggestion: 'Consider narrowband filters or a different target',
      ),
    ];
  } else if (moonDist < 30 && moonIllumination > 50) {
    return [
      TargetWarning(
        type: WarningType.moonProximity,
        severity: WarningSeverity.warning,
        message:
            'Near bright Moon (${moonDist.toStringAsFixed(0)}°) - ${moonIllumination.toStringAsFixed(0)}% illuminated',
        suggestion: 'Use narrowband filters to reduce sky glow',
      ),
    ];
  } else if (moonDist < 45 && moonIllumination > 70) {
    return [
      TargetWarning(
        type: WarningType.moonProximity,
        severity: WarningSeverity.caution,
        message: 'Moon is ${moonDist.toStringAsFixed(0)}° away',
        suggestion: 'Some sky glow may be present',
      ),
    ];
  } else if (moonIllumination >= 65) {
    // Wide separation but a bright moon still warns: moonlight raises the
    // sky background everywhere, not just near the moon.
    return [
      TargetWarning(
        type: WarningType.moonProximity,
        severity: WarningSeverity.caution,
        message:
            'Moon is ${moonIllumination.toStringAsFixed(0)}% illuminated - '
            'sky background elevated across the whole sky',
        suggestion: 'Narrowband will fare far better than broadband tonight',
      ),
    ];
  }
  return const [];
}
