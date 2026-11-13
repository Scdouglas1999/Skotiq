/// Dual-rig / multi-camera synchronized imaging — Riverpod wiring.
///
/// Surfaces the secondary (piggyback) capture rig to the UI:
///   * [secondaryRigConfigProvider] holds the user's editable config (camera
///     selection, exposure, dither-coordination policy);
///   * [secondaryRigControllerProvider] arms / stops the rig via the FRB
///     bindings;
///   * [secondaryRigStatusProvider] polls live status (frame counts, whether
///     the secondary is parked for a primary dither) for the status card +
///     headless monitoring.
///
/// v1 scope: same mount (piggyback), secondary has no own guiding/dither,
/// plate-solving, or autofocus. See the Rust `dual_rig` module for the full
/// non-goals list.
library;

import 'host_role.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;

import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'settings_provider.dart';

/// In-flight-exposure policy when the primary announces a dither.
enum SecondaryDitherPolicy {
  /// Let a short in-flight sub finish (if within max-wait), else abort it.
  completeIfShort,

  /// Always abort the in-flight secondary sub immediately.
  abortImmediately;

  String get wire => switch (this) {
    SecondaryDitherPolicy.completeIfShort => 'complete_if_short',
    SecondaryDitherPolicy.abortImmediately => 'abort_immediately',
  };

  String get label => switch (this) {
    SecondaryDitherPolicy.completeIfShort => 'Finish short subs',
    SecondaryDitherPolicy.abortImmediately => 'Abort immediately',
  };
}

/// User-editable secondary-rig configuration. Immutable; mutate via copyWith on
/// the [SecondaryRigConfigNotifier].
class SecondaryRigConfig {
  final String? cameraId;
  final double exposureSecs;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;

  /// null => run until the primary sequence ends.
  final int? frameCount;
  final String? filterName;
  final double? targetTempC;
  final String rigLabel;
  final double ditherMaxWaitSecs;
  final SecondaryDitherPolicy ditherPolicy;

  const SecondaryRigConfig({
    this.cameraId,
    this.exposureSecs = 60.0,
    this.gain,
    this.offset,
    this.binX = 1,
    this.binY = 1,
    this.frameCount,
    this.filterName,
    this.targetTempC,
    this.rigLabel = 'Secondary',
    this.ditherMaxWaitSecs = 30.0,
    this.ditherPolicy = SecondaryDitherPolicy.completeIfShort,
  });

  bool get isValid =>
      cameraId != null &&
      cameraId!.trim().isNotEmpty &&
      exposureSecs.isFinite &&
      exposureSecs >= 0.001 &&
      exposureSecs <= 86400 &&
      binX >= 1 &&
      binX <= 16 &&
      binY >= 1 &&
      binY <= 16 &&
      (frameCount == null || frameCount! > 0) &&
      ditherMaxWaitSecs.isFinite &&
      ditherMaxWaitSecs >= 0.1 &&
      ditherMaxWaitSecs <= 600 &&
      (targetTempC == null ||
          (targetTempC!.isFinite &&
              targetTempC! >= -100 &&
              targetTempC! <= 60));

  SecondaryRigConfig copyWith({
    String? cameraId,
    bool clearCamera = false,
    double? exposureSecs,
    int? gain,
    bool clearGain = false,
    int? offset,
    bool clearOffset = false,
    int? binX,
    int? binY,
    int? frameCount,
    bool clearFrameCount = false,
    String? filterName,
    bool clearFilterName = false,
    double? targetTempC,
    bool clearTargetTemp = false,
    String? rigLabel,
    double? ditherMaxWaitSecs,
    SecondaryDitherPolicy? ditherPolicy,
  }) {
    return SecondaryRigConfig(
      cameraId: clearCamera ? null : (cameraId ?? this.cameraId),
      exposureSecs: exposureSecs ?? this.exposureSecs,
      gain: clearGain ? null : (gain ?? this.gain),
      offset: clearOffset ? null : (offset ?? this.offset),
      binX: binX ?? this.binX,
      binY: binY ?? this.binY,
      frameCount: clearFrameCount ? null : (frameCount ?? this.frameCount),
      filterName: clearFilterName ? null : (filterName ?? this.filterName),
      targetTempC: clearTargetTemp ? null : (targetTempC ?? this.targetTempC),
      rigLabel: rigLabel ?? this.rigLabel,
      ditherMaxWaitSecs: ditherMaxWaitSecs ?? this.ditherMaxWaitSecs,
      ditherPolicy: ditherPolicy ?? this.ditherPolicy,
    );
  }
}

class SecondaryRigConfigNotifier extends StateNotifier<SecondaryRigConfig> {
  SecondaryRigConfigNotifier() : super(const SecondaryRigConfig());

  void reset() => state = const SecondaryRigConfig();

  void setCamera(String? cameraId) => state = cameraId == null
      ? state.copyWith(clearCamera: true)
      : state.copyWith(cameraId: cameraId);
  void setExposure(double secs) => state = state.copyWith(exposureSecs: secs);
  void setGain(int? gain) => state = gain == null
      ? state.copyWith(clearGain: true)
      : state.copyWith(gain: gain);
  void setOffset(int? offset) => state = offset == null
      ? state.copyWith(clearOffset: true)
      : state.copyWith(offset: offset);
  void setBinning(int x, int y) => state = state.copyWith(binX: x, binY: y);
  void setFrameCount(int? count) => count == null
      ? state = state.copyWith(clearFrameCount: true)
      : state = state.copyWith(frameCount: count);
  void setFilterName(String? name) => state = name == null
      ? state.copyWith(clearFilterName: true)
      : state.copyWith(filterName: name);
  void setTargetTemp(double? t) => state = t == null
      ? state.copyWith(clearTargetTemp: true)
      : state.copyWith(targetTempC: t);
  void setRigLabel(String label) => state = state.copyWith(rigLabel: label);
  void setDitherMaxWait(double secs) =>
      state = state.copyWith(ditherMaxWaitSecs: secs);
  void setDitherPolicy(SecondaryDitherPolicy p) =>
      state = state.copyWith(ditherPolicy: p);
}

final secondaryRigConfigProvider =
    StateNotifierProvider<SecondaryRigConfigNotifier, SecondaryRigConfig>((
      ref,
    ) {
      final notifier = SecondaryRigConfigNotifier();
      ref.listenAcrossHosts(
        (host) => host?.link.identity,
        (_) => notifier.reset(),
      );
      return notifier;
    });

final secondaryRigOperationInProgressProvider = StateProvider<bool>(
  (ref) => false,
);

/// Metadata the primary supplies so secondary frames inherit target identity +
/// save location. Provide the active target name + save base when arming so the
/// secondary's subs are co-located with the primary's.
class SecondaryRigStartContext {
  final String? saveBasePath;
  final String? targetName;
  final double? targetRaHours;
  final double? targetDecDegrees;
  final String? observerName;
  final double? siteLatitudeDeg;
  final double? siteLongitudeDeg;
  final double? siteElevationM;

  const SecondaryRigStartContext({
    this.saveBasePath,
    this.targetName,
    this.targetRaHours,
    this.targetDecDegrees,
    this.observerName,
    this.siteLatitudeDeg,
    this.siteLongitudeDeg,
    this.siteElevationM,
  });
}

/// Controller that arms / stops the secondary rig through the FRB bindings.
class SecondaryRigController {
  SecondaryRigController(this._ref)
    : _drive = _ref.read(_secondaryRigDriveProvider);

  final Ref _ref;
  _SecondaryRigDrive _drive;
  int _driveRevision = 0;
  Future<void> _operationTail = Future<void>.value();

  /// Arm + start the secondary capture loop. Arm BEFORE starting the primary
  /// sequence so the dither barrier is installed when the executor starts.
  Future<void> start(SecondaryRigStartContext context) {
    final drive = _drive;
    final revision = _driveRevision;
    return _serialized(() {
      _ensureAuthority(drive, revision);
      return _withBusy(revision, () => _start(context, drive));
    });
  }

  Future<void> _start(
    SecondaryRigStartContext context,
    _SecondaryRigDrive drive,
  ) async {
    final config = _ref.read(secondaryRigConfigProvider);
    if (!config.isValid) {
      throw StateError(
        'Secondary rig needs a camera and a positive exposure before starting.',
      );
    }
    final primaryCameraId = _ref.read(cameraStateProvider).deviceId;
    if (config.cameraId == primaryCameraId) {
      throw StateError(
        'The secondary camera must be different from the primary camera.',
      );
    }
    final explicitSavePath = context.saveBasePath?.trim();
    final settingsSavePath = _ref
        .read(appSettingsProvider)
        .valueOrNull
        ?.imageOutputPath
        .trim();
    final saveBasePath = explicitSavePath?.isNotEmpty == true
        ? explicitSavePath!
        : settingsSavePath;
    if (saveBasePath == null || saveBasePath.isEmpty) {
      throw StateError(
        'Choose an image output folder before starting the secondary rig.',
      );
    }

    await drive.start(config, context, saveBasePath);
  }

  Future<void> stop() {
    final drive = _drive;
    final revision = _driveRevision;
    return _serialized(() {
      _ensureAuthority(drive, revision);
      return _withBusy(revision, drive.stop);
    });
  }

  Future<bool> isArmed() async => (await getStatus()).armed;

  Future<SecondaryRigStatus> getStatus() async {
    final drive = _drive;
    final revision = _driveRevision;
    final status = await drive.status();
    _ensureAuthority(drive, revision);
    return status;
  }

  void _switchDrive(_SecondaryRigDrive drive) {
    if (identical(drive, _drive)) return;
    _drive = drive;
    _driveRevision++;
    _operationTail = Future<void>.value();
    _ref.read(secondaryRigOperationInProgressProvider.notifier).state = false;
  }

  void _ensureAuthority(_SecondaryRigDrive drive, int revision) {
    if (revision != _driveRevision || !identical(drive, _drive)) {
      throw StateError(
        'The imaging host changed before the secondary-rig action completed.',
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then(
      (_) async {
        try {
          completer.complete(await operation());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      onError: (_) async {
        try {
          completer.complete(await operation());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }

  Future<T> _withBusy<T>(int revision, Future<T> Function() operation) async {
    _ref.read(secondaryRigOperationInProgressProvider.notifier).state = true;
    try {
      return await operation();
    } finally {
      if (revision == _driveRevision) {
        _ref.read(secondaryRigOperationInProgressProvider.notifier).state =
            false;
      }
    }
  }
}

class SecondaryRigStatus {
  final bool armed;
  final bool running;
  final String? cameraId;
  final String rigLabel;
  final int framesCaptured;
  final int framesAborted;
  final int? plannedFrames;
  final bool waitingForDither;
  final bool exposing;
  final bool ditherPending;
  final int forcedProceeds;
  final String? lastError;

  const SecondaryRigStatus({
    required this.armed,
    required this.running,
    required this.cameraId,
    required this.rigLabel,
    required this.framesCaptured,
    required this.framesAborted,
    required this.plannedFrames,
    required this.waitingForDither,
    required this.exposing,
    required this.ditherPending,
    required this.forcedProceeds,
    required this.lastError,
  });

  factory SecondaryRigStatus.fromBridge(
    bridge_api.SecondaryRigStatusApi status,
  ) {
    return SecondaryRigStatus(
      armed: status.armed,
      running: status.running,
      cameraId: status.cameraId,
      rigLabel: status.rigLabel,
      framesCaptured: status.framesCaptured,
      framesAborted: status.framesAborted,
      plannedFrames: status.plannedFrames,
      waitingForDither: status.waitingForDither,
      exposing: status.exposing,
      ditherPending: status.ditherPending,
      forcedProceeds: status.forcedProceeds,
      lastError: status.lastError,
    );
  }

  factory SecondaryRigStatus.fromJson(Map<String, dynamic> json) {
    bool requiredBool(String key) {
      final value = json[key];
      if (value is bool) return value;
      throw FormatException('Secondary rig status has invalid $key');
    }

    int requiredInt(String key) {
      final value = json[key];
      if (value is num) return value.toInt();
      throw FormatException('Secondary rig status has invalid $key');
    }

    return SecondaryRigStatus(
      armed: requiredBool('armed'),
      running: requiredBool('running'),
      cameraId: json['cameraId'] as String?,
      rigLabel: json['rigLabel'] as String? ?? '',
      framesCaptured: requiredInt('framesCaptured'),
      framesAborted: requiredInt('framesAborted'),
      plannedFrames: (json['plannedFrames'] as num?)?.toInt(),
      waitingForDither: requiredBool('waitingForDither'),
      exposing: requiredBool('exposing'),
      ditherPending: requiredBool('ditherPending'),
      forcedProceeds: requiredInt('forcedProceeds'),
      lastError: json['lastError'] as String?,
    );
  }
}

/// The second camera's capture loop where it runs: this process's drivers,
/// or the linked host's.
abstract interface class _SecondaryRigDrive {
  Future<void> start(
    SecondaryRigConfig config,
    SecondaryRigStartContext context,
    String saveBasePath,
  );
  Future<void> stop();
  Future<SecondaryRigStatus> status();
}

final class _BridgeSecondaryRig implements _SecondaryRigDrive {
  const _BridgeSecondaryRig();

  @override
  Future<void> start(
    SecondaryRigConfig config,
    SecondaryRigStartContext context,
    String saveBasePath,
  ) async {
    await bridge_api.apiSecondaryRigStart(
      config: bridge_api.SecondaryRigConfigApi(
        cameraId: config.cameraId!,
        exposureSecs: config.exposureSecs,
        gain: config.gain,
        offset: config.offset,
        binX: config.binX,
        binY: config.binY,
        frameCount: config.frameCount,
        filterName: config.filterName,
        targetTempC: config.targetTempC,
        rigLabel: config.rigLabel,
        ditherMaxWaitSecs: config.ditherMaxWaitSecs,
        inFlightPolicy: config.ditherPolicy.wire,
        saveBasePath: saveBasePath,
        targetName: context.targetName,
        targetRaHours: context.targetRaHours,
        targetDecDegrees: context.targetDecDegrees,
        observerName: context.observerName,
        siteLatitudeDeg: context.siteLatitudeDeg,
        siteLongitudeDeg: context.siteLongitudeDeg,
        siteElevationM: context.siteElevationM,
      ),
    );
  }

  @override
  Future<void> stop() => bridge_api.apiSecondaryRigStop();

  @override
  Future<SecondaryRigStatus> status() async => SecondaryRigStatus.fromBridge(
    await bridge_api.apiSecondaryRigGetStatus(),
  );
}

final class _HostSecondaryRigDrive implements _SecondaryRigDrive {
  const _HostSecondaryRigDrive(this._host);

  final HostSecondaryRig _host;

  @override
  Future<void> start(
    SecondaryRigConfig config,
    SecondaryRigStartContext context,
    String saveBasePath,
  ) async {
    await _host.secondaryRigStart({
      'cameraId': config.cameraId,
      'exposureSecs': config.exposureSecs,
      if (config.gain != null) 'gain': config.gain,
      if (config.offset != null) 'offset': config.offset,
      'binX': config.binX,
      'binY': config.binY,
      if (config.frameCount != null) 'frameCount': config.frameCount,
      if (config.filterName != null) 'filterName': config.filterName,
      if (config.targetTempC != null) 'targetTempC': config.targetTempC,
      'rigLabel': config.rigLabel,
      'ditherMaxWaitSecs': config.ditherMaxWaitSecs,
      'inFlightPolicy': config.ditherPolicy.wire,
      'saveBasePath': saveBasePath,
      if (context.targetName != null) 'targetName': context.targetName,
      if (context.targetRaHours != null) 'targetRaHours': context.targetRaHours,
      if (context.targetDecDegrees != null)
        'targetDecDegrees': context.targetDecDegrees,
      if (context.observerName != null) 'observerName': context.observerName,
      if (context.siteLatitudeDeg != null)
        'siteLatitudeDeg': context.siteLatitudeDeg,
      if (context.siteLongitudeDeg != null)
        'siteLongitudeDeg': context.siteLongitudeDeg,
      if (context.siteElevationM != null)
        'siteElevationM': context.siteElevationM,
    });
  }

  @override
  Future<void> stop() => _host.secondaryRigStop();

  @override
  Future<SecondaryRigStatus> status() async =>
      SecondaryRigStatus.fromJson(await _host.secondaryRigGetStatus());
}

_SecondaryRigDrive _secondaryRigDriveOn(RemoteHost? host) => host == null
    ? const _BridgeSecondaryRig()
    : _HostSecondaryRigDrive(host.secondaryRig);

final _secondaryRigDriveProvider = hostRoleProvider<_SecondaryRigDrive>(
  here: (_) => _secondaryRigDriveOn(null),
  linked: (_, host) => _secondaryRigDriveOn(host),
);

final secondaryRigControllerProvider = Provider<SecondaryRigController>((ref) {
  final controller = SecondaryRigController(ref);
  ref.listenAcrossHosts(_secondaryRigDriveOn, controller._switchDrive);
  return controller;
});

/// Polls host-authoritative secondary-rig status. Transport errors remain
/// errors so the UI cannot mistake an unreachable rig for an idle one.
final secondaryRigStatusProvider =
    StreamProvider.autoDispose<SecondaryRigStatus?>((ref) async* {
      ref.watch(backendProvider);
      while (true) {
        final status = await ref
            .read(secondaryRigControllerProvider)
            .getStatus();
        yield status.armed ? status : null;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    });
