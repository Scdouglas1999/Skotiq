import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A native stand-in for the master build: records requests and writes the
/// files a real build would, previews included, so delivery has them.
class FakeBuildNative {
  final requests = <Map<String, dynamic>>[];
  final built = <String>[];
  double retained = .9;
  List<Map<String, dynamic>> limiting = const [];

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) async {
    requests.add(jsonDecode(jsonEncode(args)) as Map<String, dynamic>);
    switch (args['op']) {
      case 'checkCalibration':
        return {};
      case 'registrationPreview':
        return {
          'width': 100,
          'height': 80,
          'frames': [
            for (final g in args['groups'] as List)
              for (final l in g['lights'] as List)
                {
                  'path': l['path'],
                  'group': g['label'],
                  'corners': [
                    [2, 2],
                    [97, 2],
                    [97, 77],
                    [2, 77],
                  ],
                  'overlap': 1.0,
                  'included': true,
                },
          ],
          'crop': [2, 2, 97, 77],
          'retainedArea': retained,
          'minRetainedArea': args['minRetainedArea'],
          'meetsMinimum': retained >= (args['minRetainedArea'] as num),
          'limiting': limiting,
        };
      case 'build':
        final filter = args['filter'] as String;
        built.add(filter);
        for (final key in [
          'masterFitsPath',
          'coverageFitsPath',
          'previewPngPath',
        ]) {
          await File(args[key] as String).writeAsString('artifact');
        }
        final lights = [
          for (final g in args['groups'] as List)
            for (final l in g['lights'] as List) l,
        ];
        return {
          'filter': filter,
          'masterPath': args['masterFitsPath'],
          'coveragePath': args['coverageFitsPath'],
          'frameCount': lights.length,
          'totalIntegrationSec': 120.0 * lights.length,
          'folded': [
            for (final l in lights) {'path': l['path']},
          ],
          'skipped': [],
        };
      case 'deliverUniform':
        await Directory(args['outputDir'] as String).create(recursive: true);
        final files = <Map<String, dynamic>>[];
        for (final m in args['masters'] as List) {
          final file = File('${args['outputDir']}/${m['filter']}.fits');
          await file.writeAsString('linear');
          await File('${file.path}.png').writeAsString('png');
          files.add({
            'path': file.path,
            'previewPath': '${file.path}.png',
            'channels': 1,
          });
        }
        return {
          'masters': files,
          'width': 95,
          'height': 75,
          'crop': [2, 2, 97, 77],
          'retainedArea': retained,
        };
    }
    throw StateError('unexpected op ${args['op']}');
  }
}

/// Integration progress that never reports; the chain test reads outcomes.
class QuietSeam extends Fake implements PostSessionSeam {
  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();
}

/// One notification as it left the process.
class SentNotification {
  const SentNotification(this.title, this.message, this.deepLink);
  final String title;
  final String message;
  final String? deepLink;
}

/// Records every notification with its deep link.
class RecordingNotifications extends NotificationService {
  RecordingNotifications() : super.testing(settingsReader: () => null);

  final sent = <SentNotification>[];

  @override
  Future<bool> notify({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    sent.add(SentNotification(title, message, deepLink));
    return true;
  }

  @override
  Future<NotificationDispatch> notifyDetailed({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    sent.add(SentNotification(title, message, deepLink));
    return const NotificationDispatch(routed: null, webhookAccepted: true);
  }
}

/// End-of-night calibration that takes its frames at once.
class InstantCalibration extends EndOfNightCalibrationService {
  InstantCalibration() : super(_NoRig(), () async => const EonSettings());

  final reasons = <String>[];

  @override
  Future<EonReport> run({
    required String reason,
    EonSettings? settings,
    bool forceWarmUp = false,
  }) async {
    reasons.add(reason);
    final report = EonReport(reason: reason, startedAt: DateTime.now())
      ..phase = EonPhase.finished
      ..framesCaptured = 70
      ..finishedAt = DateTime.now()
      ..summary = 'Took 20 darks and 50 bias frames and built their masters.';
    state = EonStatus(phase: EonPhase.finished, report: report);
    return report;
  }
}

class _NoRig implements EonRig {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class FixedBackend extends BackendNotifier {
  FixedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Wait until [done] holds, pumping the event loop.
Future<void> settle(bool Function() done, {int rounds = 400}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The overrides a night-end container needs over [db] and [native].
List<Override> nightEndOverrides({
  required SkotiqDatabase db,
  required FakeBuildNative native,
  required RecordingNotifications notifications,
  required InstantCalibration calibration,
  required Directory mastersRoot,
}) {
  final service = DarkroomBuildService(
    operation: native.call,
    library: CalibrationLibraryService(
      db: db,
      flatLibraryDao: FlatLibraryDao(db),
      tagsDao: CalibrationTagsDao(db),
    ),
    masters: IntegratedMastersDao(db),
    readHeader: (_) async => {'NAXIS1': '100', 'NAXIS2': '80'},
  );
  return [
    databaseProvider.overrideWithValue(db),
    backendProvider.overrideWith(
      (ref) => FixedBackend(ref, FfiBackend(database: db)),
    ),
    darkroomBuildServiceProvider.overrideWithValue(service),
    darkroomMastersRootProvider.overrideWith((ref) async => mastersRoot),
    postSessionSeamProvider.overrideWithValue(QuietSeam()),
    notificationServiceProvider.overrideWithValue(notifications),
    endOfNightCalibrationProvider.overrideWith((ref) => calibration),
    guidedBuildDeliveryProvider.overrideWith(
      (ref) => GuidedBuildDelivery(
        jobs: DarkroomJobsDao(db),
        delivery: DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (destination, jobId) =>
              WatchedFolderTransport(destination: destination, jobId: jobId),
        ),
        notifications: notifications,
      ),
    ),
  ];
}
