import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/providers/darkroom_build_jobs_provider.dart';
import 'package:skotiq_core/src/providers/darkroom_build_service_provider.dart';
import 'package:skotiq_core/src/providers/darkroom_state_store_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/notification_service_provider.dart';
import 'package:skotiq_core/src/providers/output_locations_provider.dart';
import 'package:skotiq_core/src/providers/post_session_seam_provider.dart';
import 'package:skotiq_core/src/services/darkroom_build_jobs.dart';
import 'package:skotiq_core/src/services/darkroom_build_service.dart';
import 'package:skotiq_core/src/services/darkroom_state_store.dart';

class _FakePostSessionSeam implements PostSessionSeam {
  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeNotificationService implements NotificationService {
  final List<String> titles = [];

  @override
  Future<NotificationDispatch> notify({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    titles.add(title);
    return const NotificationDispatch.refused('test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FlakyDarkroomStateStore implements DarkroomStateStore {
  _FlakyDarkroomStateStore({this.failReadsRemaining = 0, this.stored});

  int failReadsRemaining;
  Map<String, dynamic>? stored;
  int readAttempts = 0;

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    readAttempts++;
    if (failReadsRemaining > 0) {
      failReadsRemaining--;
      throw StateError('transient db lock');
    }
    return stored;
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    stored = value;
  }
}

class _FakeDarkroomBuildService implements DarkroomBuildService {
  _FakeDarkroomBuildService({
    this.onPreviewRegistration,
    this.onBuildUnattended,
  });

  final Future<DarkroomRegistrationPreview> Function(
    DarkroomBuildPlan plan,
    DarkroomRegistrationPreview? previous,
  )?
  onPreviewRegistration;

  final Future<DarkroomUnattendedOutcome> Function({
    required String target,
    required List<DbCapturedImage> frames,
    required Directory directory,
    required double minRetainedArea,
    required bool requireCalibration,
    required Map<String, String> selectedFlats,
    void Function(DarkroomRegistrationPreview, DarkroomBuildPlan)? onPreview,
    void Function(DarkroomBuildStep)? onStep,
  })?
  onBuildUnattended;

  @override
  bool get isRunning => false;

  @override
  Future<DarkroomRegistrationPreview> previewRegistration(
    DarkroomBuildPlan plan, {
    DarkroomRegistrationPreview? previous,
  }) {
    final handler = onPreviewRegistration;
    if (handler != null) return handler(plan, previous);
    return Future.value(_previewFor(plan));
  }

  @override
  Future<DarkroomUnattendedOutcome> buildUnattended({
    required String target,
    required List<DbCapturedImage> frames,
    required Directory directory,
    double minRetainedArea = defaultMinRetainedArea,
    bool requireCalibration = true,
    Map<String, String> selectedFlats = const {},
    void Function(DarkroomRegistrationPreview, DarkroomBuildPlan)? onPreview,
    void Function(DarkroomBuildStep)? onStep,
  }) {
    final handler = onBuildUnattended;
    if (handler != null) {
      return handler(
        target: target,
        frames: frames,
        directory: directory,
        minRetainedArea: minRetainedArea,
        requireCalibration: requireCalibration,
        selectedFlats: selectedFlats,
        onPreview: onPreview,
        onStep: onStep,
      );
    }
    throw UnimplementedError();
  }

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DarkroomBuildPlan _makePlan({String target = 'NGC 891'}) =>
    DarkroomBuildPlan.fromJson({
      'version': 1,
      'target': target,
      'referencePath': '/lights/l1.fits',
      'minOverlap': 0.8,
      'maxEccentricity': 0.7,
      'minRetainedArea': 0.8,
      'processing': const DarkroomProcessingOptions().toJson(),
      'groups': [
        {
          'filter': 'L',
          'label': 'L-1',
          'calibration': <String, Object?>{},
          'lights': [
            {'id': 1, 'path': '/lights/l1.fits', 'exposureSec': 120.0},
            {'id': 2, 'path': '/lights/l2.fits', 'exposureSec': 120.0},
          ],
        },
      ],
    });

DarkroomRegistrationPreview _previewFor(DarkroomBuildPlan plan) =>
    DarkroomRegistrationPreview(
      width: 1000,
      height: 1000,
      frames: [
        for (final light in plan.lights)
          DarkroomFramePreview(
            path: light['path'] as String,
            group: 'L-1',
            included: true,
            corners: const [
              Offset(0, 0),
              Offset(1000, 0),
              Offset(1000, 1000),
              Offset(0, 1000),
            ],
            overlap: 1.0,
            raw: const {},
          ),
      ],
      crop: const [0, 0, 1000, 1000],
      retainedArea: 1.0,
      minRetainedArea: plan.minRetainedArea,
      meetsMinimum: true,
      limiting: const [],
    );

void main() {
  group('DarkroomBuildJobs reliability', () {
    test(
      'preserves concurrent setProcessing edits during in-flight exclude',
      () async {
        final previewGate = Completer<DarkroomRegistrationPreview>();
        var previewCalls = 0;
        final service = _FakeDarkroomBuildService(
          onPreviewRegistration: (plan, previous) {
            previewCalls++;
            if (previewCalls == 1) {
              return Future.value(_previewFor(plan));
            }
            return previewGate.future;
          },
        );
        final store = _FlakyDarkroomStateStore();
        final container = ProviderContainer(
          overrides: [
            darkroomBuildServiceProvider.overrideWithValue(service),
            darkroomStateStoreProvider.overrideWithValue(store),
            postSessionSeamProvider.overrideWithValue(_FakePostSessionSeam()),
            notificationServiceProvider.overrideWithValue(
              _FakeNotificationService(),
            ),
          ],
        );
        addTearDown(container.dispose);

        final jobs = container.read(darkroomBuildJobsProvider.notifier);
        final plan = _makePlan();
        await jobs.checkFraming(target: 'NGC 891', plan: plan);
        expect(
          container.read(darkroomBuildJobsProvider)?.stage,
          DarkroomJobStage.awaitingReview,
        );

        final excludeFuture = jobs.exclude({'/lights/l2.fits': 'cloud'});
        const edited = DarkroomProcessingOptions(
          normalization: 'local',
          drizzleScale: 2,
          pixfrac: 0.7,
        );
        jobs.setProcessing(edited);
        expect(
          container.read(darkroomBuildJobsProvider)?.plan?.processing,
          edited,
        );

        previewGate.complete(
          _previewFor(plan.withoutLights({'/lights/l2.fits': 'cloud'})),
        );
        await excludeFuture;

        final after = container.read(darkroomBuildJobsProvider)!;
        expect(after.plan!.lights.map((l) => l['path']), ['/lights/l1.fits']);
        expect(
          after.plan!.processing,
          edited,
          reason:
              'in-flight exclude must not overwrite concurrent setProcessing',
        );
      },
    );

    test(
      'dismissing awaitingReview job prevents late exclude from resurrecting it',
      () async {
        final previewGate = Completer<DarkroomRegistrationPreview>();
        var previewCalls = 0;
        final service = _FakeDarkroomBuildService(
          onPreviewRegistration: (plan, previous) {
            previewCalls++;
            if (previewCalls == 1) {
              return Future.value(_previewFor(plan));
            }
            return previewGate.future;
          },
        );
        final container = ProviderContainer(
          overrides: [
            darkroomBuildServiceProvider.overrideWithValue(service),
            darkroomStateStoreProvider.overrideWithValue(
              _FlakyDarkroomStateStore(),
            ),
            postSessionSeamProvider.overrideWithValue(_FakePostSessionSeam()),
            notificationServiceProvider.overrideWithValue(
              _FakeNotificationService(),
            ),
          ],
        );
        addTearDown(container.dispose);

        final jobs = container.read(darkroomBuildJobsProvider.notifier);
        final plan = _makePlan();
        await jobs.checkFraming(target: 'NGC 891', plan: plan);

        final excludeFuture = jobs.exclude({'/lights/l2.fits': 'cloud'});
        jobs.dismiss();
        expect(container.read(darkroomBuildJobsProvider), isNull);

        previewGate.complete(_previewFor(plan));
        await excludeFuture;

        expect(container.read(darkroomBuildJobsProvider), isNull);
      },
    );

    test(
      'startUnattended marks Stopped error as stopped without failure alert',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final targetId = await db.targetsDao.createTarget(
          TargetsCompanion.insert(name: 'NGC 891', ra: 2.37, dec: 42.34),
        );
        await db.imagesDao.insertSequenceFrame(
          filePath: '/lights/l1.fits',
          fileName: 'l1.fits',
          fileFormat: 'fits',
          exposureDuration: 120,
          capturedAt: DateTime.utc(2026, 11, 1),
          isAccepted: true,
          producingNodeId: 'n1',
          targetId: targetId,
          filter: 'L',
        );
        final notifications = _FakeNotificationService();
        final tempDir = await Directory.systemTemp.createTemp('dr_jobs_');
        addTearDown(() => tempDir.delete(recursive: true));
        final service = _FakeDarkroomBuildService(
          onBuildUnattended:
              ({
                required target,
                required frames,
                required directory,
                required minRetainedArea,
                required requireCalibration,
                required selectedFlats,
                onPreview,
                onStep,
              }) async {
                throw StateError(
                  'Stopped. Resume this folder to keep completed filters.',
                );
              },
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            darkroomBuildServiceProvider.overrideWithValue(service),
            darkroomStateStoreProvider.overrideWithValue(
              _FlakyDarkroomStateStore(),
            ),
            postSessionSeamProvider.overrideWithValue(_FakePostSessionSeam()),
            notificationServiceProvider.overrideWithValue(notifications),
            targetMastersFolderProvider(
              'NGC 891',
            ).overrideWith((_) async => tempDir),
          ],
        );
        addTearDown(container.dispose);

        final jobs = container.read(darkroomBuildJobsProvider.notifier);
        final outcome = await jobs.startUnattended('NGC 891', announce: true);

        expect(outcome.stage, DarkroomJobStage.stopped);
        expect(notifications.titles, isEmpty);
      },
    );

    test(
      'whenIdle completes cleanly on container dispose and restore retries after read failure',
      () async {
        final previewGate = Completer<DarkroomRegistrationPreview>();
        final service = _FakeDarkroomBuildService(
          onPreviewRegistration: (plan, previous) => previewGate.future,
        );
        final savedJob = DarkroomBuildJob(
          target: 'M31',
          stage: DarkroomJobStage.done,
          message: 'Masters ready',
          startedAt: DateTime.utc(2026, 11, 1),
          finishedAt: DateTime.utc(2026, 11, 1, 1),
        );
        final store = _FlakyDarkroomStateStore(
          failReadsRemaining: 1,
          stored: {'current': savedJob.toJson(), 'held': [], 'recent': []},
        );
        final container = ProviderContainer(
          overrides: [
            darkroomBuildServiceProvider.overrideWithValue(service),
            darkroomStateStoreProvider.overrideWithValue(store),
            postSessionSeamProvider.overrideWithValue(_FakePostSessionSeam()),
            notificationServiceProvider.overrideWithValue(
              _FakeNotificationService(),
            ),
          ],
        );

        final jobs = container.read(darkroomBuildJobsProvider.notifier);
        await jobs.restore();
        expect(container.read(darkroomBuildJobsProvider), isNull);
        expect(store.readAttempts, 1);

        // Second restore succeeds because the failed read was not cached.
        await jobs.restore();
        expect(container.read(darkroomBuildJobsProvider)?.target, 'M31');
        expect(store.readAttempts, 2);

        // Start an active build and verify whenIdle completes on dispose.
        final framing = jobs.checkFraming(target: 'NGC 891', plan: _makePlan());
        expect(jobs.busy, isTrue);
        final idleFuture = jobs.whenIdle();
        container.dispose();
        await idleFuture.timeout(const Duration(seconds: 2));

        previewGate.complete(_previewFor(_makePlan()));
        await framing;
      },
    );

    test(
      'an exclude and a replan in flight both keep their light-list edits',
      () async {
        final gate = Completer<DarkroomRegistrationPreview>();
        var calls = 0;
        final service = _FakeDarkroomBuildService(
          onPreviewRegistration: (plan, previous) {
            calls++;
            if (calls == 1) return Future.value(_previewFor(plan));
            if (calls == 2) return gate.future;
            return Future.value(_previewFor(plan));
          },
        );
        final container = ProviderContainer(
          overrides: [
            darkroomBuildServiceProvider.overrideWithValue(service),
            darkroomStateStoreProvider.overrideWithValue(
              _FlakyDarkroomStateStore(),
            ),
            postSessionSeamProvider.overrideWithValue(_FakePostSessionSeam()),
            notificationServiceProvider.overrideWithValue(
              _FakeNotificationService(),
            ),
          ],
        );
        addTearDown(container.dispose);

        final jobs = container.read(darkroomBuildJobsProvider.notifier);
        final plan = DarkroomBuildPlan.fromJson({
          'version': 1,
          'target': 'NGC 891',
          'referencePath': '/lights/l1.fits',
          'minOverlap': 0.8,
          'maxEccentricity': 0.7,
          'minRetainedArea': 0.8,
          'processing': const DarkroomProcessingOptions().toJson(),
          'groups': [
            {
              'filter': 'L',
              'label': 'L-1',
              'calibration': <String, Object?>{},
              'lights': [
                {'id': 1, 'path': '/lights/l1.fits', 'exposureSec': 120.0},
                {'id': 2, 'path': '/lights/l2.fits', 'exposureSec': 120.0},
                {'id': 3, 'path': '/lights/l3.fits', 'exposureSec': 120.0},
              ],
            },
          ],
        });
        await jobs.checkFraming(target: 'NGC 891', plan: plan);

        final excluded = jobs.exclude({'/lights/l2.fits': 'cloud'});
        final replanned = jobs.replan(
          plan.withoutLights({'/lights/l3.fits': 'trail'}),
        );
        gate.complete(_previewFor(plan));
        await excluded;
        await replanned;

        expect(
          container
              .read(darkroomBuildJobsProvider)!
              .plan!
              .lights
              .map((light) => light['path']),
          ['/lights/l1.fits'],
        );
      },
    );
  });
}
