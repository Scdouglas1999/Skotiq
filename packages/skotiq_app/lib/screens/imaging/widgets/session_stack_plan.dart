import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

/// Tonight's frames a live stack can start from without a file dialog.
@immutable
class SessionStackPlan {
  const SessionStackPlan({
    required this.referencePath,
    required this.framePaths,
    required this.filter,
    this.referenceHfr,
  });

  /// The sharpest frame: every other frame is registered onto it.
  final String referencePath;
  final double? referenceHfr;

  /// The rest of the group, oldest first.
  final List<String> framePaths;

  /// The group's filter; null for frames taken without one.
  final String? filter;

  int get frameCount => framePaths.length + 1;
}

/// The night's kept light frames that belong with the newest one (same
/// target, filter and binning), or null when there are none on this
/// computer.
///
/// Only the newest frame's group: a mono stack of L and Ha, or of two
/// targets, is not a picture of anything.
final sessionStackPlanProvider = Provider<SessionStackPlan?>((ref) {
  // A linked client arms the host's stacker instead; the files are the
  // host's.
  if (ref.watch(backendProvider).remoteHost != null) return null;
  return sessionStackPlanFor(ref.watch(recentSessionFramesProvider));
});

/// [sessionStackPlanProvider]'s choice over [kept], the night's kept frames
/// oldest first.
@visibleForTesting
SessionStackPlan? sessionStackPlanFor(List<CapturedImage> kept) {
  final lights = kept
      .where(
        (frame) =>
            frame.settings.frameType == FrameType.light &&
            frame.filePath.isNotEmpty,
      )
      .toList(growable: false);
  if (lights.isEmpty) return null;
  final newest = lights.last;
  bool belongs(CapturedImage frame) =>
      frame.targetName == newest.targetName &&
      frame.settings.filter == newest.settings.filter &&
      frame.settings.binningX == newest.settings.binningX &&
      frame.settings.binningY == newest.settings.binningY;
  final group = lights.where(belongs).toList(growable: false);

  var reference = group.last;
  for (final frame in group.reversed) {
    final hfr = frame.stats?.hfr;
    final best = reference.stats?.hfr;
    if (hfr != null && (best == null || hfr < best)) reference = frame;
  }
  return SessionStackPlan(
    referencePath: reference.filePath,
    referenceHfr: reference.stats?.hfr,
    framePaths: [
      for (final frame in group)
        if (!identical(frame, reference)) frame.filePath,
    ],
    filter: newest.settings.filter,
  );
}
