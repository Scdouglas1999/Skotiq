// Solve & sync: plate solve where the mount points, then sync the mount.
//
// Solves the last frame when it was taken at the current pointing; otherwise
// takes a short utility frame with the centering settings. The solve's wall
// time goes to the Solve tab through `ManualActionState.lastSolveDuration`.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../models/command_action_result.dart';

/// Where the mount pointed when a frame reached the screen.
@immutable
class FramePointing {
  const FramePointing({
    required this.capturedAt,
    required this.raHours,
    required this.decDegrees,
  });

  /// [CapturedImageData.capturedAt] of the frame this belongs to.
  final DateTime capturedAt;

  /// The mount's own read-back when the frame arrived.
  final double raHours;
  final double decDegrees;
}

/// Records the mount position for each new frame on screen.
///
/// Null when the latest frame arrived while the mount was slewing, untracked
/// or without coordinates: then nothing says where that frame points, and
/// Solve & sync takes a fresh one.
final nightFramePointingProvider =
    NotifierProvider<FramePointingRecorder, FramePointing?>(
  FramePointingRecorder.new,
);

class FramePointingRecorder extends Notifier<FramePointing?> {
  @override
  FramePointing? build() {
    ref.listen<CapturedImageData?>(currentImageProvider, (previous, next) {
      if (next == null) {
        state = null;
        return;
      }
      if (previous != null && previous.capturedAt == next.capturedAt) return;
      final mount = ref.read(mountStateProvider);
      final ra = mount.ra;
      final dec = mount.dec;
      final steady = mount.connectionState == DeviceConnectionState.connected &&
          mount.isTracking &&
          !mount.isSlewing &&
          ra != null &&
          dec != null;
      state = steady
          ? FramePointing(
              capturedAt: next.capturedAt,
              raHours: ra,
              decDegrees: dec,
            )
          : null;
    });
    return null;
  }
}

/// How far the mount may have moved since a frame and still count as the
/// same pointing: two arcminutes, well inside any imaging field.
const double kSamePointingToleranceDegrees = 2 / 60;

/// The saved file of [frame] when it was taken where [mount] points now,
/// otherwise null.
String? frameAtCurrentPointing({
  required CapturedImageData? frame,
  required FramePointing? pointing,
  required MountState mount,
}) {
  final path = frame?.filePath;
  if (frame == null || pointing == null || path == null || path.isEmpty) {
    return null;
  }
  if (pointing.capturedAt != frame.capturedAt) return null;
  final ra = mount.ra;
  final dec = mount.dec;
  if (mount.connectionState != DeviceConnectionState.connected ||
      !mount.isTracking ||
      mount.isSlewing ||
      ra == null ||
      dec == null) {
    return null;
  }
  final separation = angularSeparationDegrees(
    raHoursA: pointing.raHours,
    decDegreesA: pointing.decDegrees,
    raHoursB: ra,
    decDegreesB: dec,
  );
  return separation <= kSamePointingToleranceDegrees ? path : null;
}

/// Great-circle distance between two equatorial positions, in degrees.
double angularSeparationDegrees({
  required double raHoursA,
  required double decDegreesA,
  required double raHoursB,
  required double decDegreesB,
}) {
  const toRad = math.pi / 180;
  final ra1 = raHoursA * 15 * toRad;
  final ra2 = raHoursB * 15 * toRad;
  final d1 = decDegreesA * toRad;
  final d2 = decDegreesB * toRad;
  final cosSep = math.sin(d1) * math.sin(d2) +
      math.cos(d1) * math.cos(d2) * math.cos(ra1 - ra2);
  return math.acos(cosSep.clamp(-1.0, 1.0)) / toRad;
}

/// What a Solve & sync did.
@immutable
class SolveAndSyncResult {
  const SolveAndSyncResult({
    required this.usedLastFrame,
    this.solveDuration,
    this.raHours,
    this.decDegrees,
    this.synced = false,
    this.error,
  });

  /// True when the frame already on screen was solved.
  final bool usedLastFrame;

  /// Wall time of the solve call; null when no solve ran.
  final Duration? solveDuration;

  /// The solved J2000 position; null when the solve failed.
  final double? raHours;
  final double? decDegrees;

  final bool synced;

  /// Why it stopped short, for the log and the error banner.
  final String? error;

  bool get succeeded => synced && error == null;
}

/// The steps, injected so the order and the timing are testable.
class SolveAndSync {
  SolveAndSync({
    required this.captureSolveFrame,
    required this.solve,
    required this.sync,
    Stopwatch Function()? stopwatch,
  }) : _stopwatch = stopwatch ?? Stopwatch.new;

  /// Takes a short utility frame and returns its file path.
  final Future<String?> Function() captureSolveFrame;

  /// Solves the image at the path.
  final Future<PlateSolveResult> Function(String imagePath) solve;

  /// Syncs the mount; RA in hours, Dec in degrees, J2000.
  final Future<CommandActionResult> Function(double raHours, double decDegrees)
      sync;

  final Stopwatch Function() _stopwatch;

  /// Solves [lastFramePath] when given, otherwise a fresh frame, then syncs.
  /// [cancelled] is checked between steps; a cancelled run never syncs.
  Future<SolveAndSyncResult> run({
    String? lastFramePath,
    bool Function()? cancelled,
  }) async {
    final usedLastFrame = lastFramePath != null;
    final path = lastFramePath ?? await captureSolveFrame();
    if (path == null || path.isEmpty) {
      return SolveAndSyncResult(
        usedLastFrame: usedLastFrame,
        error: 'No solve frame was captured',
      );
    }
    if (cancelled?.call() == true) {
      return SolveAndSyncResult(
        usedLastFrame: usedLastFrame,
        error: 'Cancelled',
      );
    }

    final watch = _stopwatch()..start();
    final result = await solve(path);
    watch.stop();
    final duration = watch.elapsed;

    if (!result.success) {
      return SolveAndSyncResult(
        usedLastFrame: usedLastFrame,
        solveDuration: duration,
        error: result.error ?? 'The plate solve failed',
      );
    }
    // Solvers report RA in degrees; the mount and the app use hours.
    final raHours = result.ra / 15.0;
    final decDegrees = result.dec;
    if (cancelled?.call() == true) {
      return SolveAndSyncResult(
        usedLastFrame: usedLastFrame,
        solveDuration: duration,
        raHours: raHours,
        decDegrees: decDegrees,
        error: 'Cancelled',
      );
    }

    final synced = await sync(raHours, decDegrees);
    return SolveAndSyncResult(
      usedLastFrame: usedLastFrame,
      solveDuration: duration,
      raHours: raHours,
      decDegrees: decDegrees,
      synced: synced.isSuccess,
      error: synced.isSuccess ? null : (synced.message ?? 'Sync failed'),
    );
  }
}

/// Exposure settings for a solve frame: the manual settings with the
/// profile's centering exposure, binning, gain and offset, as the centering
/// flow uses (`slew_dropdown_button.dart` `_centeringConfig`).
ExposureSettings solveFrameSettings({
  required ExposureSettings manual,
  required EquipmentProfileModel? profile,
}) {
  final exposure = profile?.defaultCenteringExposure;
  final binning = profile?.defaultBinX ?? 2;
  var settings = manual.copyWith(
    exposureTime: exposure != null && exposure > 0 ? exposure : 5.0,
    binningX: binning,
    binningY: binning,
  );
  final gain = profile?.defaultGain;
  final offset = profile?.defaultOffset;
  if (gain != null) settings = settings.copyWith(gain: gain);
  if (offset != null) settings = settings.copyWith(offset: offset);
  return settings;
}
