import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../../database/daos/settings_dao.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import '../../utils/skotiq_data_directory.dart';
import 'pass_log.dart';
import 'pass_recorder.dart';
import 'pass_timeline.dart';

/// The one recorder of Darkroom passes, listening for as long as the app runs.
///
/// Records live next to the Darkroom's drafts (`<image output>/darkroom`) when
/// an image output directory is set, else under the app's data directory.
///
/// Read, never watched: a recorder rebuilt on a backend change would drop the
/// live logs and, through every service that reports to it, rebuild those
/// services mid-pass. A new backend is followed by re-subscribing instead.
final darkroomPassRecorderProvider = Provider<DarkroomPassRecorder>((ref) {
  final recorder = DarkroomPassRecorder(
    events: ref.read(backendProvider).eventStream,
    baseDirectory: () async {
      final db = ref.read(databaseProvider);
      final configured = (await SettingsDao(
        db,
      ).getImageOutputDirectory()).trim();
      final base = configured.isNotEmpty
          ? configured
          : (await resolveSkotiqDataDirectory()).path;
      final dir = p.join(base, 'darkroom');
      await Directory(dir).create(recursive: true);
      return dir;
    },
  );
  ref.listen(backendProvider, (previous, next) {
    if (!identical(previous, next)) recorder.listenTo(next.eventStream);
  });
  ref.onDispose(recorder.dispose);
  return recorder;
});

/// Where Dart services report about a pass.
final passReporterProvider = Provider<PassReporter>(
  (ref) => ref.watch(darkroomPassRecorderProvider),
);

/// The timeline of [runId], rebuilt on every report it receives.
final darkroomPassTimelineProvider = StreamProvider.autoDispose
    .family<PassTimeline?, String>((ref, runId) async* {
      final recorder = ref.watch(darkroomPassRecorderProvider);
      final history = await recorder.storedRates();
      PassLog? log = await recorder.load(runId);
      yield log == null ? null : PassTimeline.fromLog(log, history: history);
      await for (final changed in recorder.changes) {
        if (changed != runId) continue;
        log = recorder.live(runId) ?? log;
        if (log != null) yield PassTimeline.fromLog(log, history: history);
      }
    });

/// Every recorded pass, newest first, refreshed as passes report.
final darkroomPassRecordsProvider =
    StreamProvider.autoDispose<List<PassRecordSummary>>((ref) async* {
      final recorder = ref.watch(darkroomPassRecorderProvider);
      yield await recorder.records();
      String? last;
      await for (final runId in recorder.changes) {
        // A new pass, or one that ended, changes the list; a sub's report does not.
        final log = recorder.live(runId);
        final key = '$runId:${log?.ended}';
        if (key == last) continue;
        last = key;
        yield await recorder.records();
      }
    });

/// Asks a native integration run to stop, and drops a stop that outlived it.
class PassRunCanceller {
  const PassRunCanceller();

  /// Stop [runId] at its next stage boundary or sub; a run that has not
  /// reached the native side yet stops at its first check.
  Future<void> cancel(String runId) =>
      bridge.apiPostSessionCancel(argsJson: jsonEncode({'runId': runId}));

  /// Drop a stop that was requested after the run's last check, so the next
  /// run under the same id is not stopped by it. Refused, harmlessly, while a
  /// run is in flight.
  Future<void> clear(String runId) => bridge.apiPostSessionCancel(
    argsJson: jsonEncode({'op': 'clear', 'runId': runId}),
  );
}

final passRunCancellerProvider = Provider<PassRunCanceller>(
  (ref) => const PassRunCanceller(),
);
