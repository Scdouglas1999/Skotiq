part of '../target_scoring.dart';

extension _TargetWarnings on TargetScoringService {
  List<TargetWarning> _generateWarnings({
    required double alt,
    required double airmass,
    required double moonDist,
    required ObjectVisibility visibility,
  }) {
    final warnings = <TargetWarning>[];

    // Below horizon
    if (alt < 0) {
      warnings.add(
        TargetWarning(
          type: WarningType.belowHorizon,
          severity: WarningSeverity.critical,
          message: 'Target is below the horizon (${alt.toStringAsFixed(1)}°)',
          suggestion: visibility.riseTime != null
              ? 'Will rise at ${_formatTime(visibility.riseTime!)}'
              : null,
        ),
      );
    }
    // Very low altitude
    else if (alt < 15) {
      warnings.add(
        TargetWarning(
          type: WarningType.lowAltitude,
          severity: WarningSeverity.warning,
          message:
              'Low altitude (${alt.toStringAsFixed(1)}°) - poor seeing expected',
          suggestion: 'Consider waiting for higher altitude',
        ),
      );
    }
    // Low altitude
    else if (alt < 30) {
      warnings.add(
        TargetWarning(
          type: WarningType.lowAltitude,
          severity: WarningSeverity.caution,
          message: 'Moderate altitude (${alt.toStringAsFixed(1)}°)',
          suggestion: visibility.transitTime != null
              ? 'Best at transit: ${visibility.transitAltitude?.toStringAsFixed(0)}°'
              : null,
        ),
      );
    }

    // High airmass
    if (airmass > 2.5 && airmass.isFinite) {
      warnings.add(
        TargetWarning(
          type: WarningType.highAirmass,
          severity: WarningSeverity.warning,
          message:
              'High airmass (${airmass.toStringAsFixed(2)}) - atmospheric extinction',
          suggestion: 'Image quality may be degraded',
        ),
      );
    } else if (airmass > 2.0 && airmass.isFinite) {
      warnings.add(
        TargetWarning(
          type: WarningType.highAirmass,
          severity: WarningSeverity.caution,
          message: 'Elevated airmass (${airmass.toStringAsFixed(2)})',
        ),
      );
    }

    // Moon proximity
    warnings.addAll(_moonProximityWarnings(moonDist));

    // Setting soon
    if (visibility.setTime != null && alt > 0) {
      final minutesToSet = visibility.setTime!
          .difference(observationTime)
          .inMinutes;
      if (minutesToSet > 0 && minutesToSet < 60) {
        warnings.add(
          TargetWarning(
            type: WarningType.settingSoon,
            severity: WarningSeverity.warning,
            message: 'Setting in $minutesToSet minutes',
            suggestion: 'Start imaging soon or wait for tomorrow',
          ),
        );
      } else if (minutesToSet > 0 && minutesToSet < 120) {
        warnings.add(
          TargetWarning(
            type: WarningType.settingSoon,
            severity: WarningSeverity.caution,
            message:
                'Setting in ${(minutesToSet / 60).toStringAsFixed(1)} hours',
          ),
        );
      }
    }

    // Not yet risen
    if (alt < 0 && visibility.riseTime != null) {
      final minutesToRise = visibility.riseTime!
          .difference(observationTime)
          .inMinutes;
      if (minutesToRise > 0) {
        warnings.add(
          TargetWarning(
            type: WarningType.notYetRisen,
            severity: WarningSeverity.info,
            message:
                'Rises in ${(minutesToRise / 60).toStringAsFixed(1)} hours',
          ),
        );
      }
    }

    // Check if during twilight
    if (twilight != null) {
      final inAstroDark =
          (twilight!.astronomicalDusk != null &&
          twilight!.astronomicalDawn != null &&
          observationTime.isAfter(twilight!.astronomicalDusk!) &&
          observationTime.isBefore(twilight!.astronomicalDawn!));

      if (!inAstroDark) {
        final inNautical =
            (twilight!.nauticalDusk != null &&
            twilight!.nauticalDawn != null &&
            observationTime.isAfter(twilight!.nauticalDusk!) &&
            observationTime.isBefore(twilight!.nauticalDawn!));

        if (inNautical) {
          warnings.add(
            const TargetWarning(
              type: WarningType.twilight,
              severity: WarningSeverity.caution,
              message: 'Nautical twilight - not fully dark',
              suggestion: 'Wait for astronomical darkness for best results',
            ),
          );
        } else {
          final inCivil =
              (twilight!.civilDusk != null &&
              twilight!.civilDawn != null &&
              observationTime.isAfter(twilight!.civilDusk!) &&
              observationTime.isBefore(twilight!.civilDawn!));

          if (inCivil) {
            warnings.add(
              const TargetWarning(
                type: WarningType.twilight,
                severity: WarningSeverity.warning,
                message: 'Civil twilight - sky is still bright',
                suggestion: 'Use for flats or calibration only',
              ),
            );
          }
        }
      }
    }

    return warnings;
  }

  /// Moon-proximity warnings for a target at angular separation [moonDist]
  /// from the Moon, gated on the current [moonIllumination]. Shared verbatim
  /// by the real-time and full-night warning generators.
  List<TargetWarning> _moonProximityWarnings(double moonDist) {
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

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  /// Generate warnings based on conditions across the full night window.
  List<TargetWarning> _generateNightWarnings({
    required double peakAlt,
    required double bestAirmass,
    required double moonDist,
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

    // Moon proximity
    warnings.addAll(_moonProximityWarnings(moonDist));

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
    // Gated on the first SAMPLED instant that clears the minimum altitude, not
    // on `visibility.riseTime`. That rise time comes from a separate
    // noon-to-noon solve of the geometric horizon crossing, so for a target
    // that is already high when darkness falls it names a crossing outside the
    // night entirely — which is how M92, above 80° at astronomical dark, was
    // labelled "Rises late at 11:54", in broad daylight. A target that clears
    // the minimum at nightStart has nothing to warn about, and one that never
    // clears it is covered by the below-horizon/low-altitude warnings above.
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
            message: 'Usable only from ${_formatTime(firstObservableTime)}',
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
              message: 'Sets early at ${_formatTime(setTime)}',
              suggestion: 'Image this target early in the session',
            ),
          );
        }
      }
    }

    return warnings;
  }
}
