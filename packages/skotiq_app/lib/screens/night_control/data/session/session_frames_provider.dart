// The active session's frames, read from the captured_images table.
//
// The rows, not the in-memory `sessionImagesProvider` list, because only the
// rows carry the grader's verdict (`isAccepted`), the sensor and focuser
// readings and the solve, and because they survive an app restart. The
// session id is resolved the way `recentSessionFramesProvider` resolves it:
// the local run's id first, then, on a remote viewer that never started the
// run, the host's active session.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../night_control_contracts.dart';
import 'session_format.dart' show nightSessionNowProvider;
import 'package:skotiq_astro/skotiq_astro.dart';

/// The session whose frames Tonight shows; null when nothing is imaging.
final nightSessionIdProvider = Provider<int?>((ref) {
  final local = ref.watch(
    sessionStateProvider.select((state) => state.dbSessionId),
  );
  if (local != null) return local;
  // endSession clears SessionState; the terminal result retains the exact
  // session identity so finished-night charts and integration stay visible.
  final terminal = ref.watch(shownTerminalRunResultProvider);
  if (terminal?.dbSessionId != null &&
      ref.watch(sequenceExecutionStateProvider).canStart) {
    return terminal!.isCalibration
        ? ref.watch(completedImagingRunProvider)?.result.dbSessionId
        : terminal.dbSessionId;
  }
  if (ref.watch(backendProvider) is! NetworkBackend) return null;
  // Sorted newest first on both paths, so the first active row is the
  // host's current session.
  final sessions = ref.watch(allSessionsProvider).valueOrNull;
  if (sessions == null) return null;
  for (final session in sessions) {
    if (session.status == 'active') return session.id;
  }
  // A host that does not share its run record: a run that ended here closed
  // its session on the host, and the newest session is the one it ran.
  if (sessions.isNotEmpty && ref.watch(lastEndedRunProvider) != null) {
    return sessions.first.id;
  }
  return null;
});

final _hostSessionRowsProvider =
    StreamProvider.autoDispose.family<List<DbCapturedImage>, int>(
  (ref, sessionId) =>
      ref.watch(imagesDaoProvider).watchImagesForSession(sessionId),
);

/// The observing night Tonight shows: local noon to the next local noon,
/// the night Darkroom groups frames by. It is the night of the run Tonight
/// shows (a finished run stays on screen the next morning and afternoon),
/// else the night it is now.
final nightWindowProvider = Provider<({DateTime start, DateTime end})>((ref) {
  final run = ref.watch(nightRunRowsProvider);
  return observingNightWindow(
    run.isNotEmpty ? run.first.capturedAt : ref.watch(nightSessionNowProvider),
  );
});

final _hostNightRowsProvider = StreamProvider.autoDispose
    .family<List<DbCapturedImage>, ({DateTime start, DateTime end})>(
  (ref, window) => ref
      .watch(imagesDaoProvider)
      .watchImagesCapturedBetween(window.start, window.end),
);

/// Every captured_images row of the observing night, oldest first, across
/// every run and session it held.
///
/// The frame strip, the HFR and star charts, the session counts and the
/// integration read this. They followed one session, so a crash, an update
/// or a restart mid-night (whose restored run opens a new session) started
/// the night over on the host and on every linked client.
final nightSessionRowsProvider = Provider<List<DbCapturedImage>>((ref) {
  final window = ref.watch(nightWindowProvider);
  if (ref.watch(backendProvider) is NetworkBackend) {
    // The host's rows arrive through the remote-aware poll of all images.
    final rows = ref.watch(allDbImagesProvider).valueOrNull;
    if (rows == null) return const <DbCapturedImage>[];
    return rows
        .where(
          (row) =>
              !row.capturedAt.isBefore(window.start) &&
              row.capturedAt.isBefore(window.end),
        )
        .toList()
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }
  return ref.watch(_hostNightRowsProvider(window)).valueOrNull ??
      const <DbCapturedImage>[];
});

/// Every captured_images row of the run's own session, oldest first: what
/// the plan's progress counts. Empty without a session or while the rows
/// load.
final nightRunRowsProvider = Provider<List<DbCapturedImage>>((ref) {
  final sessionId = ref.watch(nightSessionIdProvider);
  if (sessionId == null) return const <DbCapturedImage>[];
  if (ref.watch(backendProvider) is NetworkBackend) {
    // The host's rows arrive through the remote-aware poll of all images.
    final rows = ref.watch(allDbImagesProvider).valueOrNull;
    if (rows == null) return const <DbCapturedImage>[];
    return rows.where((row) => row.sessionId == sessionId).toList()
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }
  return ref.watch(_hostSessionRowsProvider(sessionId)).valueOrNull ??
      const <DbCapturedImage>[];
});

/// The night's light frames, oldest first. Darks, flats and snapshots
/// belong to other strips.
final nightSessionLightRowsProvider = Provider<List<DbCapturedImage>>((ref) {
  return ref
      .watch(nightSessionRowsProvider)
      .where((row) => row.frameType.toLowerCase() == 'light')
      .toList(growable: false);
});

/// The run's own light frames, oldest first.
final nightRunLightRowsProvider = Provider<List<DbCapturedImage>>((ref) {
  return ref
      .watch(nightRunRowsProvider)
      .where((row) => row.frameType.toLowerCase() == 'light')
      .toList(growable: false);
});

/// The frame strip: every light frame of the session, oldest first, the
/// newest flagged for the ring.
///
/// [StripFrameVm.frameNumber] is the frame's place in the session (the 43rd
/// light is "#43"). [StripFrameVm.thumbnailPath] stays null: the sidecar
/// path lives in a raw-DDL column the Drift row does not expose, and the
/// strip loads thumbnails through the existing thumbnail service by file.
final nightSessionFramesProvider = Provider<List<StripFrameVm>>((ref) {
  final rows = ref.watch(nightSessionLightRowsProvider);
  final remote = ref.watch(backendProvider) is NetworkBackend;
  return <StripFrameVm>[
    for (var i = 0; i < rows.length; i++)
      StripFrameVm(
        id: rows[i].id,
        frameNumber: i + 1,
        capturedAt: rows[i].capturedAt,
        filter: rows[i].filter,
        exposureSecs: rows[i].exposureDuration,
        hfr: rows[i].hfr,
        starCount: rows[i].starCount,
        accepted: nightFrameVerdict(rows[i]),
        exclusion: frameExclusionKindOf(rows[i].rejectionReason),
        // The path is the host's; a remote viewer has no file there.
        filePath: remote || rows[i].filePath.isEmpty ? null : rows[i].filePath,
        hostPath: rows[i].filePath.isEmpty ? null : rows[i].filePath,
        isNewest: i == rows.length - 1,
      ),
  ];
});

/// The grader's verdict on [row]: false when it was rejected, true when it
/// was kept, null when nothing measured it. `isAccepted` defaults to true, so
/// a kept frame with no HFR, star count or quality score was never graded.
bool? nightFrameVerdict(DbCapturedImage row) {
  if (!row.isAccepted) return false;
  final measured =
      row.hfr != null || row.starCount != null || row.qualityScore != null;
  return measured ? true : null;
}

/// The session frame number of the row saved at [filePath], or null.
int? nightFrameNumberForPath(List<DbCapturedImage> lights, String? filePath) {
  if (filePath == null || filePath.isEmpty) return null;
  for (var i = lights.length - 1; i >= 0; i--) {
    if (lights[i].filePath == filePath) return i + 1;
  }
  return null;
}
