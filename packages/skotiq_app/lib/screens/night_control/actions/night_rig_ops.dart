// The rig commands Tonight's manual actions issue, behind one seam.
//
// [ServiceNightRigOps] routes each one to the service the rest of the app
// already uses for it; the controller's orchestration tests swap in a fake.
// Nothing here parks the mount or stops a run: there is no such method.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../models/command_action_result.dart';
import '../../../services/manual_capture_controller.dart';
import '../../../services/mount_command_service.dart';
import '../../../services/sequence_action_service.dart';
import 'solve_and_sync.dart';

/// Equatorial coordinates of the target to center on.
class NightCenterTarget {
  const NightCenterTarget({
    this.name,
    required this.raHours,
    required this.decDegrees,
  });

  /// Null for a session target set without a name.
  final String? name;
  final double raHours;
  final double decDegrees;
}

abstract interface class NightRigOps {
  Future<CommandActionResult> pauseRun();
  Future<CommandActionResult> resumeRun();
  Future<CommandActionResult> startRun();

  /// One utility frame with the manual settings. Throws on failure.
  Future<void> snapshot();

  /// Loops until [stopCapture]; completes when the loop ended.
  Future<void> loop({required void Function(String error) onError});

  /// Aborts the snapshot or loop started through these ops.
  void stopCapture();

  /// Throws on failure or cancellation.
  Future<AutofocusResult> autofocus();
  Future<void> cancelAutofocus();

  /// Solves the last frame when it is at the current pointing, otherwise a
  /// fresh one, then syncs.
  Future<SolveAndSyncResult> solveAndSync({bool Function()? cancelled});

  /// Aborts the solve frame's exposure, if one is in flight. A running solve
  /// cannot be interrupted; [solveAndSync] skips the sync after it.
  void cancelSolve();

  Future<CenteringResult> center(NightCenterTarget target);
  Future<void> cancelCenter();

  bool get isGuiding;
  Future<void> stopGuiding();

  /// Starts guiding and completes once the guider reports settled. Throws
  /// when it does not settle.
  Future<void> startGuidingAndSettle();

  /// Dithers and completes once settled. Throws on failure.
  Future<void> dither();

  /// Standalone meridian flip. Returns the failure text, null on success.
  Future<String?> flip();

  Future<CommandActionResult> setTracking(bool enabled);

  /// Throws on failure.
  Future<void> setCooler({required bool enabled, double? targetTemp});
}

final nightRigOpsProvider = Provider<NightRigOps>(ServiceNightRigOps.new);

class ServiceNightRigOps implements NightRigOps {
  ServiceNightRigOps(this._ref);

  final Ref _ref;

  /// The service exposing the solve frame, while it does.
  ImagingService? _solveCapture;

  SequenceActionService get _sequence =>
      _ref.read(sequenceActionServiceProvider);
  DeviceService get _devices => _ref.read(deviceServiceProvider);
  ManualCaptureController get _capture =>
      _ref.read(manualCaptureControllerProvider.notifier);
  Phd2Controller get _guider => _ref.read(phd2ControllerProvider);

  AppSettingsState? get _settings => _ref.read(appSettingsProvider).valueOrNull;

  @override
  Future<CommandActionResult> pauseRun() => _sequence.pause();

  @override
  Future<CommandActionResult> resumeRun() => _sequence.resume();

  @override
  Future<CommandActionResult> startRun() => _sequence.start();

  @override
  Future<void> snapshot() => _capture.snapshot(persist: false);

  @override
  Future<void> loop({required void Function(String error) onError}) =>
      _capture.loop(onError: onError);

  @override
  void stopCapture() => _capture.stop();

  // The same request as the dashboard's quick action: persisted autofocus
  // settings supply every field, the explicit values are only fallbacks.
  @override
  Future<AutofocusResult> autofocus() => _devices.runAutofocus(
        exposureTime: 3.0,
        stepSize: 100,
        stepsOut: 7,
        method: 'VCurve',
        binning: 1,
        useSettingsDefaults: true,
      );

  @override
  Future<void> cancelAutofocus() => _devices.cancelAutofocus();

  @override
  Future<SolveAndSyncResult> solveAndSync({bool Function()? cancelled}) {
    final mount = _ref.read(mountStateProvider);
    final lastFrame = frameAtCurrentPointing(
      frame: _ref.read(currentImageProvider),
      pointing: _ref.read(nightFramePointingProvider),
      mount: mount,
    );
    final imaging = _ref.read(imagingServiceProvider);
    final solver = _ref.read(plateSolveServiceProvider);
    final mountCommands = _ref.read(mountCommandServiceProvider);
    return SolveAndSync(
      captureSolveFrame: () async {
        _solveCapture = imaging;
        final CapturedImageData? frame;
        try {
          frame = await imaging.captureUtilityFrame(
            settings: solveFrameSettings(
              manual: _ref.read(exposureSettingsProvider),
              profile: _ref.read(activeEquipmentProfileProvider),
            ),
            targetName: _ref.read(sessionStateProvider).targetName,
          );
        } finally {
          _solveCapture = null;
        }
        if (frame != null) {
          _ref.read(currentImageProvider.notifier).state = frame;
        }
        return frame?.filePath;
      },
      solve: (path) => solver.solveWithFallback(
        imagePath: path,
        hintRaHours: mount.ra,
        hintDecDegrees: mount.dec,
      ),
      sync: mountCommands.sync,
    ).run(lastFramePath: lastFrame, cancelled: cancelled);
  }

  @override
  void cancelSolve() => _solveCapture?.cancelExposure();

  @override
  Future<CenteringResult> center(NightCenterTarget target) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final profile = _ref.read(activeEquipmentProfileProvider);
    final exposure = profile?.defaultCenteringExposure;
    return _ref.read(centeringServiceProvider).centerOnTarget(
          targetRa: target.raHours,
          targetDec: target.decDegrees,
          solverConfig: PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: settings.astapPath,
            timeoutSeconds: settings.plateSolveTimeout,
            searchRadius: settings.plateSolveSearchRadius,
          ),
          // As the slew-and-center dialog builds it.
          config: CenteringConfig(
            maxIterations: 5,
            toleranceArcsec: 30.0,
            exposureTime: exposure != null && exposure > 0 ? exposure : 5.0,
            binning: profile?.defaultBinX ?? 2,
            gain: profile?.defaultGain,
            offset: profile?.defaultOffset,
            syncMount: settings.centeringSyncMount,
          ),
          onStatusUpdate: (status) =>
              _ref.read(centeringStatusProvider.notifier).state = status,
        );
  }

  @override
  Future<void> cancelCenter() => _ref.read(centeringServiceProvider).stop();

  @override
  bool get isGuiding => _ref.read(guiderStateProvider).isGuiding;

  @override
  Future<void> stopGuiding() => _guider.stopGuiding();

  ({double pixels, double time, double timeout}) get _settle {
    final s = _settings;
    // The Guiding screen's own clamps (guiding_screen_parts/actions.dart).
    return (
      pixels: (s?.settleThreshold ?? 1.5).clamp(0.5, 5.0).toDouble(),
      time: (s?.settleTime ?? 10).toDouble().clamp(5.0, 60.0),
      timeout: (s?.settleTimeout ?? 60).toDouble().clamp(30.0, 180.0),
    );
  }

  @override
  Future<void> startGuidingAndSettle() async {
    final settle = _settle;
    final backend = _ref.read(backendProvider);
    final settled = Completer<void>();
    // Subscribed before the start command so an early SettleDone is not
    // missed. A failed settle reaches the app as StarLost.
    final subscription = backend.eventStream.listen((event) {
      if (event.category != EventCategory.guiding || settled.isCompleted) {
        return;
      }
      switch (event.eventType) {
        case 'SettleDone':
          settled.complete();
        case 'StarLost':
          settled.completeError(
              StateError('Guiding lost the star while settling'));
        case 'GuidingStopped':
          settled.completeError(StateError('Guiding stopped while settling'));
      }
    });
    try {
      await _guider.startGuiding(
        settlePixels: settle.pixels,
        settleTime: settle.time,
        settleTimeout: settle.timeout,
      );
      // Calibration can precede the first settle, so allow it a few minutes
      // on top of PHD2's own settle timeout.
      await settled.future.timeout(
        Duration(seconds: settle.timeout.round() + 300),
        onTimeout: () =>
            throw TimeoutException('Guiding did not report settled'),
      );
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> dither() {
    final settle = _settle;
    final s = _settings;
    return _guider.dither(
      amount: _ditherPixels(s?.ditherScale),
      raOnly: s?.ditherRaOnly == true,
      settlePixels: settle.pixels,
      settleTime: settle.time,
      settleTimeout: settle.timeout,
    );
  }

  /// The Guiding screen's scale-to-pixels mapping.
  static double _ditherPixels(String? scale) => switch (scale) {
        'Small' => 2.0,
        'Large' => 10.0,
        _ => 5.0,
      };

  @override
  Future<String?> flip() async {
    final ok = await _ref
        .read(meridianFlipStandaloneMonitorProvider.notifier)
        .executeNow();
    if (ok) return null;
    return _ref.read(flipLastErrorProvider) ?? 'The meridian flip failed';
  }

  @override
  Future<CommandActionResult> setTracking(bool enabled) =>
      _ref.read(mountCommandServiceProvider).setTracking(enabled);

  @override
  Future<void> setCooler({required bool enabled, double? targetTemp}) async {
    final devices = _devices;
    if (enabled) devices.cancelWarmCamera();
    await devices.setCameraCooling(enabled: enabled, targetTemp: targetTemp);
    final camera = _ref.read(cameraStateProvider.notifier);
    if (camera.mounted) camera.setCooling(enabled);
  }
}
