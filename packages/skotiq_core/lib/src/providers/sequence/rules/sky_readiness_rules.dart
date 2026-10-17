import 'dart:math' as math;

import '../../../models/equipment/equipment_models.dart';
import '../../../models/imaging/imaging_models.dart' show FrameType;
import '../../../models/scheduler/scheduler_status.dart' show SchedulerConfig;
import '../../../models/sequence/sequence_models.dart';
import '../../../services/scheduler/sky_calculations.dart';
import '../../equipment/mount_state_provider.dart';
import '../../settings_provider.dart';
import '../sequence_validation.dart';

// Sky-readiness rules — will this run, started right now, actually see sky?
//
// Without them, pre-flight reports "Ready with Warnings" for runs the engine
// refuses categorically (daylight), for runs it judges against Null Island (no
// observing site), and for runs that expose at whatever the mount happens to be
// pointing at.

/// The Sun altitude above which the executor refuses on-sky light frames.
///
/// Mirrors the native gate's `DEFAULT_MAX_SUN_ALTITUDE_DEGREES` through the
/// scheduler config that already carries the same number, so pre-flight and the
/// engine cannot drift apart.
final double _maxSunAltitudeDegrees =
    SchedulerConfig.defaults.maxSunAltitudeDegrees;

/// Enabled light-frame exposures reachable in this sequence.
bool _capturesLightFrames(Sequence sequence) {
  return sequence.nodes.values.any(
    (node) =>
        node.isEnabled &&
        node is ExposureNode &&
        node.frameType == FrameType.light &&
        node.count > 0 &&
        node.durationSecs > 0,
  );
}

/// True when the sequence itself holds until darkness — a Wait node with a
/// twilight or until-time condition, or a target whose start condition is a
/// crossing trigger. Such a run is *meant* to begin in daylight and wait, so
/// the daylight gate is not a categorical refusal for it.
bool _waitsBeforeImaging(Sequence sequence) {
  return sequence.nodes.values.any((node) {
    if (!node.isEnabled) return false;
    if (node is WaitTimeNode) {
      return node.waitUntil != null || node.waitForTwilight != null;
    }
    if (node is TargetHeaderNode) {
      return node.startWhen != null || node.startAfter != null;
    }
    return false;
  });
}

/// Pre-flight rule: the run cannot capture a single light frame because the
/// Sun is up.
///
/// The executor's daylight gate refuses every on-sky light exposure while the
/// Sun is above [_maxSunAltitudeDegrees] — the run dies in the same millisecond
/// it starts, with zero frames. Pre-flight has the site and the clock, so it
/// knows this before the operator commits; presenting it as a yellow warning
/// beside an enabled "Start Anyway" was the exact failure pre-flight exists to
/// prevent. Always an error: no strictness setting makes an impossible run
/// possible.
class DaylightGateRule implements RefAwareSequenceValidator {
  /// Injectable so tests can pin an instant instead of racing the real Sun.
  final DateTime Function() clock;

  DaylightGateRule({DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  @override
  String get name => 'DaylightGate';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    if (!_capturesLightFrames(sequence)) return const [];
    if (_waitsBeforeImaging(sequence)) return const [];

    // No site => the Sun's altitude is unknowable. ObserverLocationUnsetRule
    // owns that case and says so in those words.
    final site = ctx.ref.read(appObserverLocationProvider);
    if (site == null) return const [];

    final (sunAltitude, _) = SkyCalculations.sunAltAz(
      time: clock().toUtc(),
      latitudeDegrees: site.latitude,
      longitudeDegrees: site.longitude,
    );
    if (sunAltitude <= _maxSunAltitudeDegrees) return const [];

    return [
      ValidationIssue(
        severity: ValidationSeverity.error,
        category: ValidationCategory.timing,
        title: 'Daylight Gate Will Refuse Every Light Frame',
        description:
            'The Sun is ${sunAltitude.toStringAsFixed(1)}° above the horizon at '
            'your site, and the executor refuses on-sky light exposures above '
            '${_maxSunAltitudeDegrees.toStringAsFixed(1)}°. Started now this '
            'sequence would fail on its first exposure with zero frames '
            'captured.',
        resolutionHint:
            'Start after dark, or add a Wait node set to a twilight condition '
            'so the run holds until the sky is dark. Daytime flats, darks and '
            'bias frames are unaffected.',
      ),
    ];
  }
}

/// Pre-flight rule: no observing site, so nothing that depends on where the
/// telescope is can be evaluated.
///
/// An absent location is UNKNOWN, not (0°, 0°). Judging the run against Null
/// Island made the executor refuse every light frame of an Australian night as
/// "Sun altitude 69.6°" — blaming the Sun for a missing setting. The gate now
/// abstains without a site; pre-flight has to say why the protection is off.
class ObserverLocationUnsetRule implements RefAwareSequenceValidator {
  @override
  String get name => 'ObserverLocationUnset';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    if (!_capturesLightFrames(sequence)) return const [];
    if (ctx.ref.read(appObserverLocationProvider) != null) return const [];

    return const [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.settings,
        title: 'No Observing Location Set',
        description:
            'Skotiq does not know where your telescope is, so it cannot '
            'tell whether the Sun is up, how high a target sits, or when a '
            'meridian flip is due. This run proceeds with the daylight gate '
            'and the altitude limits switched off.',
        resolutionHint:
            'Set your latitude and longitude in Settings → Location.',
      ),
    ];
  }
}

/// Pre-flight rule: the sequence images a target it never points at.
///
/// A target node carries coordinates, but only a Slew or Center instruction
/// moves the mount. Without one the run exposes at wherever the mount already
/// is and still files every frame under the target's name — the engine logs
/// "altitude −13.3° is below the horizon" while History shows N accepted frames
/// of a target that is a patch of ground.
class MountOffTargetRule implements RefAwareSequenceValidator {
  /// How far the mount may sit from the target before this is worth saying.
  /// Wider than any framing error, narrower than a wrong object.
  static const double toleranceDegrees = 5.0;

  @override
  String get name => 'MountOffTarget';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final mount = ctx.ref.read(mountStateProvider);
    if (mount.connectionState != DeviceConnectionState.connected) {
      return const [];
    }
    final mountRa = mount.ra;
    final mountDec = mount.dec;
    if (mountRa == null || mountDec == null) return const [];

    // One pointing instruction anywhere in the sequence is enough to abstain:
    // operators legitimately put a Slew or Center above the target rather than
    // under it, and a false block on a run that does point the mount would be
    // worse than the miss this rule exists to catch.
    final pointsTheMount = sequence.nodes.values.any(
      (node) =>
          node.isEnabled &&
          (node is SlewNode || node is CenterNode || node is MeridianFlipNode),
    );
    if (pointsTheMount) return const [];

    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! TargetHeaderNode) continue;
      if (!node.isEnabled) continue;
      if (node.raHours == 0.0 && node.decDegrees == 0.0) continue;

      final capturesLight = sequence.descendantsOf(node.id).any((id) {
        final child = sequence.nodes[id];
        return child is ExposureNode &&
            child.isEnabled &&
            child.frameType == FrameType.light &&
            child.count > 0;
      });
      if (!capturesLight) continue;

      final separation = _angularSeparationDegrees(
        ra1Hours: node.raHours,
        dec1Degrees: node.decDegrees,
        ra2Hours: mountRa,
        dec2Degrees: mountDec,
      );
      if (separation <= toleranceDegrees) continue;

      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.targets,
          affectedNodeId: node.id,
          title: 'Mount Is Not Pointing At ${node.targetName}',
          description:
              'The mount is ${separation.toStringAsFixed(0)}° away from '
              '${node.targetName} and this target has no Slew or Center '
              'instruction, so the run would expose wherever the mount happens '
              'to be and file every frame under ${node.targetName}.',
          resolutionHint:
              'Add a "Slew to Target" or "Center Target" instruction under the '
              'target, or slew there first with the toolbar button.',
        ),
      );
    }
    return issues;
  }
}

/// Great-circle separation between two equatorial positions, in degrees.
double _angularSeparationDegrees({
  required double ra1Hours,
  required double dec1Degrees,
  required double ra2Hours,
  required double dec2Degrees,
}) {
  const degreesPerHour = 15.0;
  final ra1 = ra1Hours * degreesPerHour * math.pi / 180.0;
  final ra2 = ra2Hours * degreesPerHour * math.pi / 180.0;
  final dec1 = dec1Degrees * math.pi / 180.0;
  final dec2 = dec2Degrees * math.pi / 180.0;
  final cosSeparation =
      math.sin(dec1) * math.sin(dec2) +
      math.cos(dec1) * math.cos(dec2) * math.cos(ra1 - ra2);
  return math.acos(cosSeparation.clamp(-1.0, 1.0)) * 180.0 / math.pi;
}
