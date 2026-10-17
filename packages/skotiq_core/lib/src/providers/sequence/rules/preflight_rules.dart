import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/network_backend.dart';
import '../../../database/database.dart' show DarkLibraryEntry, Target;
import '../../../models/backend/device_types.dart';
import '../../../models/calibration/remote_calibration_models.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/imaging/imaging_models.dart' show FrameType;
import '../../../models/sequence/sequence_models.dart';
import '../../../services/dark_library_coverage_service.dart';
import '../../backend_provider.dart';
import '../../capability_provider.dart';
import '../../dark_library_provider.dart';
import '../../equipment/camera_state_provider.dart';
import '../../equipment/filter_wheel_state_provider.dart';
import '../../equipment/focuser_state_provider.dart';
import '../../equipment_health_provider.dart';
import '../../preflight_providers.dart';
import '../../database_provider.dart';
import '../../settings_provider.dart';
import '../sequence_validation.dart';

// Pre-flight check validation rules.
//
// These rules wire the existing `dark_library_service`,
// `equipment_health_service`, and `optical_train_diagnostics_service`
// into the unified sequence validator so the pre-flight dialog can
// surface their findings before a run starts.
//
// Severity is variable per the user's `PreflightStrictness` setting:
//
//   * lax     — most issues degrade to `info`. Only hard errors block.
//   * normal  — default. Most issues are `warning`.
//   * strict  — non-trivial issues become `error` (blocks start).
//
// The mapping is centralised in [_severityFor] below so the rules stay
// short.

/// Maps a base severity (the "normal" mode value) to the actual severity
/// to emit based on the user's strictness setting.
///
/// `info` issues never escalate (they're informational by definition).
/// `warning` issues degrade to `info` under lax and escalate to `error`
/// under strict. `error` issues always remain errors.
ValidationSeverity _severityFor(
  ValidationSeverity base,
  PreflightStrictness strictness,
) {
  if (base == ValidationSeverity.info) return base;
  if (base == ValidationSeverity.error) return base;
  // base == warning
  switch (strictness) {
    case PreflightStrictness.lax:
      return ValidationSeverity.info;
    case PreflightStrictness.normal:
      return ValidationSeverity.warning;
    case PreflightStrictness.strict:
      return ValidationSeverity.error;
  }
}

/// Maps a host dark-library row (fetched over the wire on a remote-client
/// slave) into the local Drift [DarkLibraryEntry] shape the
/// [DarkLibraryCoverageService] evaluates. Only the fields the coverage
/// evaluator reads (frame type, gain/offset, binning, exposure, temperature,
/// master-dark path/quorum) need to round-trip faithfully.
DarkLibraryEntry _darkEntryFromRemote(RemoteDarkLibraryEntry r) {
  return DarkLibraryEntry(
    id: r.id,
    filePath: r.filePath,
    exposureTime: r.exposureDuration,
    temperature: r.sensorTempC,
    gain: r.gain,
    offset: r.offset,
    binX: r.binX,
    binY: r.binY,
    frameType: r.frameType,
    width: r.width,
    height: r.height,
    masterDarkPath: r.masterPath,
    masterFrameCount: r.frameCount,
    createdAt: r.createdAt,
  );
}

/// Compact key identifying a dark-coverage combination.
/// Pre-flight rule: dark library coverage.
///
/// Walks every enabled light-frame exposure in the sequence, collects the
/// (gain, offset, target_temp, duration, binning) signatures, and queries
/// the dark library for matching frames. Missing combinations and
/// below-quorum coverage are surfaced as a single grouped warning so the
/// dialog doesn't drown the user in N near-identical issues.
///
/// Matches the dark library's tolerance window: ±0.5°C on temperature,
/// ±1s on duration. The duration tolerance is enforced here (DAO does
/// exact match) by widening the search around the requested exposure.
class DarkLibraryCoverageRule implements AsyncSequenceValidator {
  @override
  String get name => 'DarkLibraryCoverage';

  @override
  Future<List<ValidationIssue>> validate(
    Sequence sequence,
    ValidationContext ctx,
  ) async {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    // Collect distinct light-frame combos. ExposureNode does not model a
    // per-exposure temperature, so the operative value is the sensor setpoint
    // the run will be AT when the node executes: whatever the most recent
    // preceding Cool Camera node asked for, and only the camera's live
    // setpoint before the first one. Reading the live setpoint for the whole
    // sequence checked (and offered to capture) darks at the camera default
    // for a run whose Cool Camera node cools to something else entirely.
    final cameraState = ref.read(cameraStateProvider);
    final uncooled = await _cameraCannotRegulateTemperature(ref, cameraState);
    // A camera with no cooler never reaches the profile's setpoint, so darks
    // captured to satisfy a setpoint requirement could never match a light
    // frame — the check sent operators off to spend an hour producing
    // calibration data that was useless by construction. What the lights will
    // actually be taken at is the sensor's own reading.
    final camTargetTemp = uncooled
        ? (cameraState.temperature ?? cameraState.targetTemp)
        : cameraState.targetTemp;
    final plannedTemps = _plannedSensorTemps(sequence, camTargetTemp);
    var anyPlannedByNode = false;

    final requirements = <DarkFrameRequirement>{};
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      if (!node.isEnabled) continue;
      if (node.frameType != FrameType.light) continue;
      if (node.durationSecs <= 0) continue;
      if (node.count <= 0) continue;

      final gain = node.gain ?? settings.defaultGain;
      final offset = node.offset ?? settings.defaultOffset;
      final binValue = _binningToInt(node.binning);
      final binX = binValue;
      final binY = binValue;
      final plannedTemp = plannedTemps.containsKey(node.id)
          ? plannedTemps[node.id]
          : camTargetTemp;
      if (plannedTemp != camTargetTemp) anyPlannedByNode = true;
      requirements.add(
        DarkFrameRequirement(
          gain: gain,
          offset: offset,
          durationSecs: node.durationSecs,
          binX: binX,
          binY: binY,
          targetTemp: plannedTemp,
        ),
      );
    }

    if (requirements.isEmpty) return const [];

    // Query the dark library. On a remote-client slave the local dark library
    // table is empty (it is never populated on a slave), so reading the local
    // DAO would mark every required combination as "missing" and raise a false
    // "Missing Dark Frames" pre-flight warning even though the master holds the
    // darks. Pull the host's real library over the wire instead and map the
    // remote rows into DarkLibraryEntry so the coverage evaluator agrees with
    // the master; keep the local DAO path on the host.
    final backend = ref.read(backendProvider);
    final List<DarkLibraryEntry> entries;
    if (backend is NetworkBackend) {
      final remoteDarks = await backend.listDarks();
      entries = remoteDarks.map(_darkEntryFromRemote).toList(growable: false);
    } else {
      final service = ref.read(darkLibraryServiceProvider);
      entries = await service.getAllEntries();
    }
    final coverage = const DarkLibraryCoverageService().evaluate(
      requirements: requirements,
      entries: entries,
      minCoverage: settings.darkLibraryMinCoverage,
      // Same tolerances the runtime calibration matcher uses, so
      // the pre-flight badge and `findMatchingDark` agree.
      tolerances: ref.read(darkLibraryMatchTolerancesProvider),
    );
    final missing = coverage.missing;
    final underCovered = coverage.underCovered;

    if (missing.isEmpty && underCovered.isEmpty) {
      return const [];
    }

    final issues = <ValidationIssue>[];
    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );

    // Name where the temperature in each line came from, so an operator who
    // expects the camera's current setpoint can see the sequence overrode it.
    final tempSource = anyPlannedByNode
        ? '\nTemperatures are the setpoints this sequence cools to.'
        : uncooled
        ? '\nThis camera has no cooler, so the temperature is its current '
              'sensor reading.'
        : '';

    if (missing.isNotEmpty) {
      final lines = missing.map((r) => '  • ${r.describe()}').join('\n');
      issues.add(
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.darkLibrary,
          title: 'Missing Dark Frames',
          description:
              'No matching darks found for ${missing.length} exposure combination'
              '${missing.length == 1 ? "" : "s"}:\n$lines$tempSource',
          // Name the destination the navigation actually has. There is no
          // "Calibration" entry anywhere in the app: the dark library lives at
          // Settings > Equipment > Dark Library, and a hint that names a screen
          // the user cannot find is worse than no hint.
          resolutionHint:
              'Capture darks for the missing combinations. Open Settings → '
              'Equipment → Dark Library to schedule them, or run the '
              '"Capture missing darks" action from the pre-flight dialog.',
        ),
      );
    }

    if (underCovered.isNotEmpty) {
      final lines = underCovered.entries
          .map(
            (e) =>
                '  • ${e.key.describe()} — ${e.value} of ${settings.darkLibraryMinCoverage} frames',
          )
          .join('\n');
      issues.add(
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.darkLibrary,
          title: 'Low Dark Library Coverage',
          description:
              'Some combinations have fewer than ${settings.darkLibraryMinCoverage} '
              'darks (below the configured quorum):\n$lines$tempSource',
          resolutionHint:
              'Capture additional darks to reach the quorum, then create a '
              'master dark from Settings → Equipment → Dark Library.',
        ),
      );
    }

    return issues;
  }
}

/// True when the connected camera cannot regulate its sensor temperature, so
/// its cooling setpoint is a number nothing will ever honour.
///
/// Unknown capabilities (no camera, no id, driver does not report) keep the
/// setpoint — the only honest answer when we cannot tell whether a cooler
/// exists.
Future<bool> _cameraCannotRegulateTemperature(
  Ref ref,
  CameraStateSnapshot camera,
) async {
  if (camera.connectionState != DeviceConnectionState.connected) return false;
  final deviceId = camera.deviceId;
  if (deviceId == null || deviceId.isEmpty) return false;
  final capabilities = await ref.read(
    cameraCapabilitiesProvider(deviceId).future,
  );
  return capabilities != null && !capabilities.canSetCcdTemperature;
}

/// Sensor setpoint each enabled exposure node will execute at, keyed by node id.
///
/// Walks the tree in execution order threading the setpoint: a Cool Camera node
/// changes it for everything that follows (cooling is camera-wide state, so the
/// change outlives the branch it sits in). [initial] is the camera's live
/// setpoint, used until the first Cool Camera node.
///
/// Nodes unreachable from the root are absent from the result; the caller falls
/// back to the live setpoint for those, which is all it can honestly assume.
@visibleForTesting
Map<String, double?> plannedSensorTemps(Sequence sequence, double? initial) =>
    _plannedSensorTemps(sequence, initial);

Map<String, double?> _plannedSensorTemps(Sequence sequence, double? initial) {
  final temps = <String, double?>{};
  final root = sequence.rootNodeId;
  if (root == null || sequence.nodes[root] == null) return temps;

  var current = initial;
  void walk(String nodeId) {
    final node = sequence.nodes[nodeId];
    if (node == null || !node.isEnabled) return;
    if (node is CoolCameraNode) {
      current = node.targetTemp;
    } else if (node is ExposureNode) {
      temps[node.id] = current;
    }
    for (final childId in node.childIds) {
      walk(childId);
    }
  }

  walk(root);
  return temps;
}

class _HistoricalQualityBucket {
  int attempted = 0;
  int rejected = 0;
  int hfrRejected = 0;
}

/// Pre-flight rule: warn when recent history says this target/filter has been
/// troublesome before.
///
/// This intentionally lives in the async pre-flight tier: it queries persisted
/// capture history and should not run on every tree edit. Warnings are advisory
/// only, even in strict pre-flight mode.
class HistoryDrivenQualityRule implements AsyncSequenceValidator {
  static const int minSampleSize = 8;
  static const double highRejectRate = 0.30;
  static const double hfrRejectRate = 0.20;
  static const int hfrRejectCount = 3;
  static const double coordinateMatchRaHours = 0.05;
  static const double coordinateMatchDecDegrees = 1.0;

  @override
  String get name => 'HistoryDrivenQuality';

  @override
  Future<List<ValidationIssue>> validate(
    Sequence sequence,
    ValidationContext ctx,
  ) async {
    final targetNodes = sequence.nodes.values
        .whereType<TargetHeaderNode>()
        .where((node) => node.isEnabled)
        .toList(growable: false);
    if (targetNodes.isEmpty) return const [];

    final dbTargets = await ctx.ref.read(allDbTargetsProvider.future);
    if (dbTargets.isEmpty) return const [];

    final allImages = await ctx.ref.read(allDbImagesProvider.future);

    final issues = <ValidationIssue>[];
    for (final target in targetNodes) {
      final dbTarget = _resolveTarget(target, dbTargets);
      if (dbTarget == null) continue;

      final plannedFilters = _plannedFilters(sequence, target);
      final frames = allImages
          .where((frame) => frame.targetId == dbTarget.id)
          .toList(growable: false);
      final buckets = <String, _HistoricalQualityBucket>{};

      for (final frame in frames) {
        if (frame.frameType.toLowerCase() != 'light') continue;
        final filter = _filterKey(frame.filter);
        if (plannedFilters.isNotEmpty && !plannedFilters.contains(filter)) {
          continue;
        }
        final bucket = buckets.putIfAbsent(
          filter,
          () => _HistoricalQualityBucket(),
        );
        bucket.attempted += 1;
        if (!frame.isAccepted) {
          bucket.rejected += 1;
          if (_looksHfrRelated(frame.rejectionReason)) {
            bucket.hfrRejected += 1;
          }
        }
      }

      for (final entry in buckets.entries) {
        final bucket = entry.value;
        if (bucket.attempted < minSampleSize) continue;

        final rejectRate = bucket.rejected / bucket.attempted;
        final hfrRate = bucket.hfrRejected / bucket.attempted;
        if (rejectRate >= highRejectRate) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.equipmentHealth,
              affectedNodeId: target.id,
              title: 'High Previous Rejection Rate',
              description:
                  '${target.targetName} has ${bucket.rejected} rejected light '
                  'frames out of ${bucket.attempted} recent ${entry.key} '
                  'captures (${(rejectRate * 100).round()}%).',
              resolutionHint:
                  'Review recent rejected frames before starting. Consider '
                  'tightening focus cadence, checking guiding, or using a '
                  'brighter backup target if conditions are marginal.',
            ),
          );
        }

        if (bucket.hfrRejected >= hfrRejectCount || hfrRate >= hfrRejectRate) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.equipmentHealth,
              affectedNodeId: target.id,
              title: 'Previous HFR Rejections',
              description:
                  '${target.targetName} previously had ${bucket.hfrRejected} '
                  'HFR/focus-related rejected ${entry.key} frames out of '
                  '${bucket.attempted} attempts.',
              resolutionHint:
                  'Start with a fresh autofocus run and consider a shorter '
                  'autofocus interval for this target/filter.',
            ),
          );
        }
      }
    }

    return issues;
  }

  Target? _resolveTarget(TargetHeaderNode node, List<Target> targets) {
    final wanted = _normalizeName(node.targetName);
    for (final target in targets) {
      final name = _normalizeName(target.name);
      final catalogId = target.catalogId;
      if (name == wanted ||
          (catalogId != null && _normalizeName(catalogId) == wanted)) {
        return target;
      }
    }

    for (final target in targets) {
      final ra = target.ra;
      final dec = target.dec;
      if ((ra - node.raHours).abs() <= coordinateMatchRaHours &&
          (dec - node.decDegrees).abs() <= coordinateMatchDecDegrees) {
        return target;
      }
    }
    return null;
  }

  Set<String> _plannedFilters(Sequence sequence, TargetHeaderNode target) {
    final filters = <String>{};
    for (final childId in sequence.descendantsOf(target.id)) {
      final child = sequence.nodes[childId];
      if (child == null || !child.isEnabled) continue;
      if (child is ExposureNode) {
        filters.add(_filterKey(child.filter));
      } else if (child is SmartExposureNode) {
        for (final plan in child.plans) {
          filters.add(_filterKey(plan.filterName));
        }
      }
    }
    return filters;
  }

  String _normalizeName(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String _filterKey(String? filter) {
    final value = filter?.trim();
    if (value == null || value.isEmpty) return 'unknown filter';
    return value;
  }

  bool _looksHfrRelated(String? reason) {
    if (reason == null) return false;
    final lower = reason.toLowerCase();
    return lower.contains('hfr') ||
        lower.contains('focus') ||
        lower.contains('fwhm') ||
        lower.contains('star size');
  }
}

/// Pre-flight rule: USB stability over the last 24 hours.
///
/// Reads [deviceHealthSnapshotsProvider] and warns when any device has
/// recorded > 3 disconnects in the last 24h, or is currently unhealthy
/// (per `EquipmentHealthService`'s existing heuristic).
class UsbStabilityRule implements RefAwareSequenceValidator {
  @override
  String get name => 'UsbStability';

  /// Threshold above which the disconnect count is considered
  /// suspicious. Matches the threshold called out in the strategic
  /// report.
  static const int disconnectThreshold = 3;

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    final snapshots = ref.read(deviceHealthSnapshotsProvider);
    if (snapshots.isEmpty) return const [];

    final flagged = snapshots
        .where((s) {
          return s.disconnectCountLast24h > disconnectThreshold || !s.isHealthy;
        })
        .toList(growable: false);
    if (flagged.isEmpty) return const [];

    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );
    final issues = <ValidationIssue>[];
    for (final snap in flagged) {
      final reason = !snap.isHealthy
          ? 'currently unhealthy (heartbeat stale)'
          : '${snap.disconnectCountLast24h} disconnects in the last 24 hours';
      issues.add(
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.equipmentHealth,
          title: 'USB Stability Concern',
          description: '${snap.displayName} is $reason.',
          resolutionHint:
              'Check the USB cable, hub, and power supply for ${snap.displayName}. '
              'Marginal cables typically cause the longest unattended-run '
              'failures.',
        ),
      );
    }
    return issues;
  }
}

/// Pre-flight rule: focuser position near hard stop.
///
/// Warns if the focuser is within 100 steps of either travel limit. The
/// rule is a no-op if the focuser doesn't report position or max
/// position (relative focusers report neither).
class FocuserRangeRule implements RefAwareSequenceValidator {
  @override
  String get name => 'FocuserRange';

  /// Number of steps from each travel limit considered "at the edge".
  static const int edgeMarginSteps = 100;

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    // Only relevant if the sequence will touch the focuser (autofocus
    // node or any node that requires focuser). Don't pester users
    // running an exposure-only sequence with no focus mention.
    final requiresFocuser = sequence.nodes.values.any((node) {
      if (!node.isEnabled) return false;
      return node.requiredDevices.contains(DeviceType.focuser);
    });
    if (!requiresFocuser) return const [];

    final focuser = ref.read(focuserStateProvider);
    if (focuser.connectionState != DeviceConnectionState.connected) {
      // Connection-presence is the equipment_rules's job; we just
      // skip silently here.
      return const [];
    }
    final pos = focuser.position;
    final maxPos = focuser.maxPosition;
    if (pos == null || maxPos == null) return const [];

    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );

    if (pos <= edgeMarginSteps) {
      return [
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.equipmentHealth,
          title: 'Focuser Near Inner Travel Limit',
          description:
              'Focuser position $pos is within $edgeMarginSteps steps of the inner '
              'stop. Autofocus may saturate at the limit.',
          resolutionHint:
              'Move the focuser out a few hundred steps before starting, '
              'or recheck back-focus.',
        ),
      ];
    }
    if (pos >= (maxPos - edgeMarginSteps)) {
      return [
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.equipmentHealth,
          title: 'Focuser Near Outer Travel Limit',
          description:
              'Focuser position $pos is within $edgeMarginSteps steps of the outer '
              'stop (max $maxPos). Autofocus may saturate at the limit.',
          resolutionHint:
              'Move the focuser in a few hundred steps before starting, '
              'or recheck back-focus.',
        ),
      ];
    }
    return const [];
  }
}

/// Pre-flight rule: polar alignment freshness.
///
/// Reads [lastPolarAlignmentAnywhereProvider] and compares the timestamp
/// to the user's [AppSettingsState.polarAlignmentMaxAgeDays]. Stale
/// alignment fires a strictness-dependent severity.
///
/// "No alignment recorded" is treated as info (we don't know whether
/// the rig is permanent and was aligned outside Skotiq).
class PolarAlignmentFreshnessRule implements RefAwareSequenceValidator {
  @override
  String get name => 'PolarAlignmentFreshness';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];
    if (settings.polarAlignmentMaxAgeDays <= 0) return const [];

    // Only relevant if a mount is required for this run.
    final requiresMount = sequence.nodes.values.any((node) {
      if (!node.isEnabled) return false;
      return node.requiredDevices.contains(DeviceType.mount);
    });
    if (!requiresMount) return const [];

    final lastAsync = ref.read(lastPolarAlignmentAnywhereProvider);
    final entry = lastAsync.valueOrNull;

    if (entry == null) {
      // No alignment ever recorded. Don't escalate even in strict mode
      // — the user may have used a different tool. Info-only nudge.
      if (!lastAsync.isLoading) {
        return const [
          ValidationIssue(
            severity: ValidationSeverity.info,
            category: ValidationCategory.equipmentHealth,
            title: 'No Polar Alignment Recorded',
            description:
                'No polar alignment has been recorded in Skotiq. If the '
                'mount is portable, run polar alignment before starting.',
            resolutionHint:
                'Open Polar Alignment from the Equipment screen (mount '
                'profiles) or Sequencer toolbar, or ignore this if the mount '
                'is permanently aligned outside Skotiq.',
          ),
        ];
      }
      return const [];
    }

    final ageDays = DateTime.now().difference(entry.completedAt).inDays.abs();
    if (ageDays <= settings.polarAlignmentMaxAgeDays) {
      return const [];
    }

    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );
    return [
      ValidationIssue(
        severity: severity,
        category: ValidationCategory.equipmentHealth,
        title: 'Polar Alignment Is Stale',
        description:
            'Last polar alignment was $ageDays days ago '
            '(threshold ${settings.polarAlignmentMaxAgeDays} days). '
            'Final error was ${entry.finalTotalError.toStringAsFixed(1)} arcmin.',
        resolutionHint:
            'Re-run polar alignment from the Equipment screen or Sequencer '
            'toolbar, or raise the freshness threshold in Settings → Pre-Flight.',
      ),
    ];
  }
}

/// Pre-flight rule: system clock drift relative to NTP.
///
/// Async because we have to hit the network. Failure to reach the NTP
/// server is surfaced as `info` (not warning) — we cannot conflate "no
/// internet" with "your clock is wrong".
///
/// A 30-second drift is always an error regardless of strictness because
/// it would falsify the FITS DATE-OBS keyword, breaking any downstream
/// astrometry / scheduling work.
class TimeSyncRule implements AsyncSequenceValidator {
  @override
  String get name => 'TimeSync';

  static const double warningThresholdSecs = 2.0;
  static const double errorThresholdSecs = 30.0;

  @override
  Future<List<ValidationIssue>> validate(
    Sequence sequence,
    ValidationContext ctx,
  ) async {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    final probe = ref.read(timeSyncProbeProvider);
    try {
      final result = await probe.queryOffset();
      final drift = result.absOffsetSeconds;

      if (drift < warningThresholdSecs) {
        return const [];
      }

      if (drift >= errorThresholdSecs) {
        // Always an error — a 30 s skew would falsify FITS timestamps
        // and scheduler calculations. We do NOT degrade this under
        // `lax`. Strictness can't make a wrong clock acceptable.
        return [
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.equipmentHealth,
            title: 'System Clock Drift > 30 s',
            description:
                'System clock differs from ${result.server} by '
                '${result.offsetSeconds.toStringAsFixed(1)} s. FITS timestamps '
                'and the scheduler will be wrong.',
            resolutionHint:
                'Enable automatic time sync in your OS (Windows: Settings → '
                'Time & Language → Sync now; Linux: `sudo timedatectl set-ntp '
                'true`; macOS: System Settings → Date & Time → Set automatically).',
          ),
        ];
      }

      final severity = _severityFor(
        ValidationSeverity.warning,
        settings.preflightStrictness,
      );
      return [
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.equipmentHealth,
          title: 'System Clock Drift',
          description:
              'System clock differs from ${result.server} by '
              '${result.offsetSeconds.toStringAsFixed(1)} s.',
          resolutionHint:
              'Run a time-sync (Settings → Date & Time) before starting.',
        ),
      ];
    } catch (e) {
      return [
        ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.equipmentHealth,
          title: 'Time Sync Check Unavailable',
          description:
              'Could not contact NTP server to verify the system clock: $e',
          resolutionHint:
              'This is normal on observatory networks without internet. '
              'Verify your system clock manually before unattended runs.',
        ),
      ];
    }
  }
}

/// Pre-flight rule: cooler ambient delta.
///
/// Warns when the camera's target setpoint is well below the current
/// camera temperature reading (read as a proxy for ambient temperature
/// pre-cooling). A ZWO ASI2600 typically achieves -30..-40 °C below
/// ambient; if the requested setpoint exceeds the camera's cooling
/// headroom, the cooler will run at 100% and never reach setpoint, which
/// usually destabilises mid-run.
class CoolerDeltaRule implements RefAwareSequenceValidator {
  @override
  String get name => 'CoolerDelta';

  /// Maximum realistic delta below ambient the average cooled CMOS
  /// camera can sustain. Conservatively 35 °C — actual cameras span
  /// 30 (older / smaller TEC) to 45 (high-end QHY mono).
  static const double maxRealisticDeltaC = 35.0;

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    final cam = ref.read(cameraStateProvider);
    if (cam.connectionState != DeviceConnectionState.connected) return const [];
    final ambient = cam.temperature;
    if (ambient == null) return const [];

    final delta = ambient - cam.targetTemp;
    if (delta <= maxRealisticDeltaC) return const [];

    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );
    return [
      ValidationIssue(
        severity: severity,
        category: ValidationCategory.equipmentHealth,
        title: 'Cooler May Not Reach Setpoint',
        description:
            'Ambient/sensor is ${ambient.toStringAsFixed(1)}°C, target '
            'is ${cam.targetTemp.toStringAsFixed(1)}°C — '
            '${delta.toStringAsFixed(0)}°C below ambient exceeds typical '
            'TEC headroom (~${maxRealisticDeltaC.toStringAsFixed(0)}°C).',
        resolutionHint:
            'Raise the target temperature in the cooling controls, or wait '
            'for ambient to drop before starting.',
      ),
    ];
  }
}

/// Pre-flight rule: filter wheel must report a known current position.
///
/// A filter wheel that has not been homed since power-on will report a
/// null current position. Starting a sequence in that state means the
/// first filter change will move from an unknown index, potentially
/// landing on the wrong slot.
class FilterWheelHomingRule implements RefAwareSequenceValidator {
  @override
  String get name => 'FilterWheelHoming';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    // Only relevant when the sequence will actually use a filter wheel.
    final requiresFw = sequence.nodes.values.any((node) {
      if (!node.isEnabled) return false;
      return node.requiredDevices.contains(DeviceType.filterWheel);
    });
    if (!requiresFw) return const [];

    final fw = ref.read(filterWheelStateProvider);
    if (fw.connectionState != DeviceConnectionState.connected) return const [];
    if (fw.currentPosition != null) return const [];

    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );
    return [
      ValidationIssue(
        severity: severity,
        category: ValidationCategory.equipmentHealth,
        title: 'Filter Wheel Not Homed',
        description:
            'The filter wheel reports no current position. It has likely '
            'not been homed since power-on; the first filter change may '
            'land on the wrong slot.',
        resolutionHint:
            'Home the filter wheel from the Filter Wheel panel before '
            'starting the sequence.',
      ),
    ];
  }
}

/// Pre-flight rule: optical-train drift vs. last session baseline.
///
/// Reads [opticalTrainCurrentSnapshotProvider] and
/// [opticalTrainBaselineProvider]. If both are present and the drift
/// exceeds [AppSettingsState.opticalTrainDriftThreshold], the rule
/// warns "your optical train has shifted since last session".
///
/// No baseline and no current snapshot are both info-only — they mean
/// "first run" and "first run before any captures", respectively.
class OpticalTrainPreflightRule implements RefAwareSequenceValidator {
  @override
  String get name => 'OpticalTrainPreflight';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final ref = ctx.ref;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return const [];

    final current = ref.read(opticalTrainCurrentSnapshotProvider);
    final baseline = ref.read(opticalTrainBaselineProvider);

    if (current == null) {
      // No live snapshot yet — we can't compare. Skip silently rather
      // than flooding the dialog on every empty / brand-new install.
      return const [];
    }
    if (baseline == null) {
      // We have a current snapshot but no baseline. Surface an info
      // note so the user knows the baseline will be captured on this
      // run.
      return const [
        ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.opticalTrain,
          title: 'Optical Train Baseline Will Be Captured',
          description:
              'No prior optical-train baseline is on record. This run '
              'will establish one for future pre-flight comparisons.',
        ),
      ];
    }

    final dTilt = (current.tiltScore - baseline.tiltScore).abs();
    final dColl = (current.collimationScore - baseline.collimationScore).abs();
    final drift = dTilt * 0.5 + dColl * 0.5;

    if (drift < settings.opticalTrainDriftThreshold) return const [];

    final severity = _severityFor(
      ValidationSeverity.warning,
      settings.preflightStrictness,
    );
    return [
      ValidationIssue(
        severity: severity,
        category: ValidationCategory.opticalTrain,
        title: 'Optical Train Has Shifted',
        description:
            'Tilt/collimation diagnostics moved ${drift.toStringAsFixed(1)} '
            'units since last session (threshold '
            '${settings.opticalTrainDriftThreshold.toStringAsFixed(1)}). '
            'Tilt Δ ${dTilt.toStringAsFixed(1)}, '
            'collimation Δ ${dColl.toStringAsFixed(1)}.',
        resolutionHint:
            'Recheck spacers, tilter, and focuser backfocus before a long '
            'run — or accept the baseline shift in Analytics → Optical Train.',
      ),
    ];
  }
}

/// Numeric value (1..4) of a [BinningMode] for DAO comparisons.
int _binningToInt(BinningMode mode) {
  switch (mode) {
    case BinningMode.one:
      return 1;
    case BinningMode.two:
      return 2;
    case BinningMode.three:
      return 3;
    case BinningMode.four:
      return 4;
  }
}

/// Returns true if the supplied list of dark-library entries has at
/// least one master dark for the requested combination. Exposed for
/// the dialog's "capture missing darks" deep-link.
bool darkLibraryHasMatchingMaster(
  List<DarkLibraryEntry> entries, {
  required int gain,
  required int offset,
  required double durationSecs,
  required int binX,
  required int binY,
  double? targetTemp,
}) {
  return entries.any((e) {
    if (e.frameType != 'dark') return false;
    if (e.masterDarkPath == null) return false;
    if (e.gain != gain) return false;
    if (e.offset != offset) return false;
    if (e.binX != binX) return false;
    if (e.binY != binY) return false;
    if ((e.exposureTime - durationSecs).abs() > 1.0) return false;
    if (targetTemp != null && e.temperature != null) {
      if ((e.temperature! - targetTemp).abs() > 0.5) return false;
    }
    return true;
  });
}
