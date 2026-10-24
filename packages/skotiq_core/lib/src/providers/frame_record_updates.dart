// Facts that arrive about a saved frame after its `captured_images` row was
// written: a plate solve, the frame watch's assessment. They find the row by
// the path the frame was saved at, and wait for the row's insert when it is
// still in flight.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../backend/ffi_backend.dart' show FfiBackend;
import '../database/daos/images_dao.dart';
import '../services/logging_service.dart';
import '../services/wcs/wcs_sip_codec.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// The `captured_images` inserts still in flight, by file path, so a later
/// update to the same frame can wait for its row instead of missing it.
class FrameRegistrationTracker {
  final Map<String, Set<Future<void>>> _pending = {};

  /// Track [registration], the insert of the row for [filePath].
  void track(String filePath, Future<void> registration) {
    if (filePath.isEmpty) return;
    final set = _pending.putIfAbsent(filePath, () => <Future<void>>{});
    set.add(registration);
    unawaited(
      registration.catchError((Object _) {}).whenComplete(() {
        final current = _pending[filePath];
        if (current == null) return;
        current.remove(registration);
        if (current.isEmpty) _pending.remove(filePath);
      }),
    );
  }

  /// Completes once every insert tracked for [filePath] has settled.
  Future<void> settled(String filePath) async {
    final set = _pending[filePath];
    if (set == null || set.isEmpty) return;
    await Future.wait(set.map((f) => f.catchError((Object _) {})));
  }
}

final frameRegistrationTrackerProvider = Provider<FrameRegistrationTracker>(
  (ref) => FrameRegistrationTracker(),
);

/// Write a successful solve to the `captured_images` row of the frame at
/// [filePath], RA in hours as every row keeps it. Returns whether a row was
/// updated. A failed solve is never written, so it cannot erase a success.
Future<bool> writeFrameSolveToRow(
  ImagesDao dao,
  String filePath, {
  required double raDegrees,
  required double decDegrees,
  required double rotationDegrees,
  required double pixelScaleArcsec,
  double? cd1_1,
  double? cd1_2,
  double? cd2_1,
  double? cd2_2,
  String? sip,
}) async {
  if (!raDegrees.isFinite ||
      !decDegrees.isFinite ||
      !pixelScaleArcsec.isFinite ||
      pixelScaleArcsec <= 0) {
    return false;
  }
  final row = await dao.getLatestImageByFilePath(filePath);
  if (row == null) return false;
  final hasCd =
      cd1_1 != null &&
      cd1_2 != null &&
      cd2_1 != null &&
      cd2_2 != null &&
      [cd1_1, cd1_2, cd2_1, cd2_2].every((v) => v.isFinite) &&
      (cd1_1 != 0 || cd1_2 != 0 || cd2_1 != 0 || cd2_2 != 0);
  await dao.updatePlateSolveResult(
    row.id,
    solvedRa: raDegrees / 15.0,
    solvedDec: decDegrees,
    solvedRotation: rotationDegrees.isFinite ? rotationDegrees : 0.0,
    solvedPixelScale: pixelScaleArcsec,
    solvedCd1_1: hasCd ? cd1_1 : null,
    solvedCd1_2: hasCd ? cd1_2 : null,
    solvedCd2_1: hasCd ? cd2_1 : null,
    solvedCd2_2: hasCd ? cd2_2 : null,
    solvedSip: hasCd ? sip : null,
  );
  return true;
}

/// Keeps the background plate solve of a frame on screen with the frame's
/// `captured_images` row, so a sequence frame's solve outlives the preview.
/// Written straight to the row (not through the records repository, whose
/// solve write also folds the frame into the sky atlas). A no-op on a linked
/// client, whose database is not the host's.
typedef BackgroundSolveRecorder =
    Future<void> Function(String filePath, bridge.PlateSolveResult result);

final backgroundSolveRecorderProvider = Provider<BackgroundSolveRecorder>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  if (backend is! FfiBackend) return (_, _) async {};
  final dao = ref.watch(imagesDaoProvider);
  final tracker = ref.watch(frameRegistrationTrackerProvider);
  final logger = ref.watch(loggingServiceProvider);
  return (filePath, result) async {
    if (!result.success) return;
    try {
      await tracker.settled(filePath);
      await writeFrameSolveToRow(
        dao,
        filePath,
        raDegrees: result.ra,
        decDegrees: result.dec,
        rotationDegrees: result.rotation,
        pixelScaleArcsec: result.pixelScale,
        cd1_1: result.cd11,
        cd1_2: result.cd12,
        cd2_1: result.cd21,
        cd2_2: result.cd22,
        sip: encodeSolvedSip(
          aOrder: result.sipAOrder,
          bOrder: result.sipBOrder,
          aCoeffs: result.sipACoeffs,
          bCoeffs: result.sipBCoeffs,
          apOrder: result.sipApOrder,
          bpOrder: result.sipBpOrder,
          apCoeffs: result.sipApCoeffs,
          bpCoeffs: result.sipBpCoeffs,
        ),
      );
    } catch (e) {
      logger.warning(
        'Could not save the background solve of $filePath with its frame '
        'record: $e',
        source: 'FrameAutoSolver',
      );
    }
  };
});
