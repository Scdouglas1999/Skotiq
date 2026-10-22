import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/database.dart' show CapturedImage;
import '../../models/equipment/equipment_models.dart'
    show DeviceConnectionState;
import '../../models/sequence/active_plan_owner.dart';
import '../../models/sequence/sequence_models.dart';
import '../../providers/backend_provider.dart';
import '../../providers/dark_library_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/equipment/camera_state_provider.dart';
import '../../providers/equipment/filter_wheel_state_provider.dart';
import '../../providers/equipment/guider_state_provider.dart';
import '../../providers/equipment/mount_state_provider.dart';
import '../../providers/sequence/sequence_executor.dart';
import '../../providers/sequence/sequence_progress.dart';
import '../../providers/sequence/sequence_selection.dart';
import '../../providers/sequence_stats_provider.dart';
import '../calibration_master_builder.dart';
import '../camera_warmup_controller.dart' show CameraWarmupOutcome;
import '../device_service.dart';
import '../mount_home_watcher.dart' show MountHomeOutcome;
import '../notification_service.dart';
import 'eon_plan.dart';
import 'eon_service.dart';
import 'eon_settings.dart';

/// [EonRig] over the app's providers.
class ProviderEonRig implements EonRig {
  ProviderEonRig(this._ref);

  final Ref _ref;

  @override
  DateTime now() => DateTime.now();

  @override
  Future<List<CapturedImage>> lightFramesSince(DateTime since) {
    final db = _ref.read(databaseProvider);
    return (db.select(db.capturedImages)
          ..where(
            (t) =>
                t.capturedAt.isBiggerOrEqualValue(since) &
                t.frameType.equals('light'),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.capturedAt)]))
        .get();
  }

  bool _connected(DeviceConnectionState state, String? id) =>
      state == DeviceConnectionState.connected && id != null && id.isNotEmpty;

  @override
  Future<EonCameraInfo?> camera() async {
    final snapshot = _ref.read(cameraStateProvider);
    final id = snapshot.deviceId;
    if (!_connected(snapshot.connectionState, id)) return null;
    try {
      final status = await _ref.read(backendProvider).getCameraStatus(id!);
      return EonCameraInfo(
        canCool: status.canCool,
        coolerOn: status.coolerOn,
        targetTempC: status.targetTemp,
        sensorTempC: status.sensorTemp,
      );
    } catch (_) {
      return EonCameraInfo(
        canCool: snapshot.isCooling,
        coolerOn: snapshot.isCooling,
        targetTempC: snapshot.targetTemp,
        sensorTempC: snapshot.temperature,
      );
    }
  }

  @override
  Future<List<String>?> filterNames() async {
    final wheel = _ref.read(filterWheelStateProvider);
    if (!_connected(wheel.connectionState, wheel.deviceId)) return null;
    // The driver's own slot names, not a cached copy: the dark slot is
    // chosen by name and must be the slot the wheel will actually move to.
    try {
      return await _ref
          .read(backendProvider)
          .filterWheelGetNames(wheel.deviceId!);
    } catch (_) {
      return wheel.filterNames;
    }
  }

  @override
  Future<String?> stopGuiding() async {
    final guider = _ref.read(guiderStateProvider);
    if (!_connected(guider.connectionState, guider.deviceId) ||
        !guider.isGuiding) {
      return null;
    }
    await _ref.read(deviceServiceProvider).stopGuiding();
    return 'Guiding stopped';
  }

  @override
  Future<String> secureMount(EonMountAction action) async {
    final mount = _ref.read(mountStateProvider);
    if (!_connected(mount.connectionState, mount.deviceId)) {
      return 'No mount is connected';
    }
    final devices = _ref.read(deviceServiceProvider);
    switch (action) {
      case EonMountAction.leave:
        return 'Mount left where the night ended';
      case EonMountAction.park:
        if (mount.isParked) return 'Mount was already parked';
        await devices.parkMount();
        return 'Mount parked';
      case EonMountAction.home:
        if (mount.isParked) {
          return 'Mount was already parked, so it was left parked';
        }
        final outcome = await devices.findMountHome();
        var tracking = 'tracking off';
        try {
          await devices.setMountTracking(false);
        } catch (e) {
          tracking = 'could not turn tracking off: $e';
        }
        return outcome == MountHomeOutcome.confirmed
            ? 'Mount sent home and reports it is at home; $tracking'
            : 'Mount sent home (the driver cannot confirm it); $tracking';
    }
  }

  @override
  Future<EonRunResult> runSequence(Sequence sequence) async {
    final before = _ref.read(sequenceTerminalRunResultProvider)?.generation;
    final done = Completer<SequenceTerminalRunResult>();
    final subscription = _ref.listen<SequenceTerminalRunResult?>(
      sequenceTerminalRunResultProvider,
      (_, next) {
        if (next != null && next.generation != before && !done.isCompleted) {
          done.complete(next);
        }
      },
    );
    try {
      _ref
          .read(currentSequenceProvider.notifier)
          .takeOwnership(sequence, ActivePlanOwner.calibration);
      await _ref.read(sequenceExecutorProvider).start();
      final result = await done.future;
      return EonRunResult(runId: result.runId, runStatus: result.runStatus);
    } finally {
      subscription.close();
    }
  }

  @override
  Future<void> stopRun() => _ref
      .read(sequenceExecutorProvider)
      .stop(origin: 'end-of-night calibration');

  @override
  Future<List<CapturedImage>> framesOfRun(int runId) => _ref
      .read(imagesDaoProvider)
      .getImagesByProducingRun(producingRunId: '$runId');

  @override
  Future<CalibrationMasterBuildResult> buildMaster(
    CalibrationMasterBuildRequest request,
  ) => _ref.read(calibrationMasterBuildProvider)(request);

  @override
  Future<int> registerMaster(
    CalibrationMasterBuildResult built,
    String frameType,
  ) => _ref
      .read(darkLibraryServiceProvider)
      .registerMaster(built, frameType: frameType);

  @override
  Future<String> warmUpCamera() async {
    final outcome = await _ref.read(deviceServiceProvider).warmCamera();
    return switch (outcome) {
      CameraWarmupOutcome.started => 'Camera warm-up started',
      CameraWarmupOutcome.coolerAlreadyOff => 'The cooler was already off',
      CameraWarmupOutcome.idleCoolerSwitchedOff =>
        'The cooler was idle and was switched off',
      CameraWarmupOutcome.canceled => 'Camera warm-up was canceled',
    };
  }

  @override
  Future<void> notify(
    String title,
    String message, {
    bool problem = false,
  }) async {
    try {
      await _ref
          .read(notificationServiceProvider)
          .notify(
            event: problem
                ? NotificationEvent.error
                : NotificationEvent.sequenceComplete,
            title: title,
            message: message,
            priority: problem
                ? NotificationPriority.high
                : NotificationPriority.normal,
          );
    } catch (_) {
      // A notification that cannot be sent must not end the step; the report
      // still carries the same text.
    }
  }

  @override
  Future<void> saveReport(Map<String, Object?> report) => _ref
      .read(settingsDaoProvider)
      .setSetting(EonSettings.lastReportKey, jsonEncode(report));
}

final endOfNightCalibrationProvider =
    StateNotifierProvider<EndOfNightCalibrationService, EonStatus>((ref) {
      return EndOfNightCalibrationService(
        ProviderEonRig(ref),
        () => EonSettings.load(ref.read(settingsDaoProvider)),
      );
    });

/// Whether the run in progress takes only calibration frames. Weather and
/// dawn safing leave such a run alone: darks cannot be spoiled by daylight or
/// cloud, and the mount has already been sent out of the way.
final calibrationOnlyRunActiveProvider = Provider<bool>((ref) {
  final state = ref.watch(sequenceExecutionStateProvider);
  if (state.canStart) return false;
  final sequence = ref.watch(currentSequenceProvider);
  return sequence != null && isCalibrationOnlySequence(sequence);
});
