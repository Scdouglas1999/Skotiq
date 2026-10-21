// Tests for [AutoIntegrationService.maybeRunForSession] — the unattended
// "wake up to a finished image" hook fired at run completion.
//
// The flagship case is multi-filter: a target with an accumulating master for
// ONE filter must not silently drop the subs of every other filter. The service
// routes each filter bucket independently (fold into its accumulating master
// when present, else batch-integrate) and reports the total subs across all
// filters.
//
// Runs against an in-memory database for the DAO-backed providers; the two
// heavy orchestration services (accumulate + batch integrate) are faked so the
// routing decision is observable without native code.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/auto_integration_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Fake accumulation service that records every `addNight` it is asked to run
/// and echoes a result reflecting the folded sub count. All other members throw
/// (they are never reached on the auto-integration path under test).
class _FakeAccumulationService implements MasterAccumulationService {
  final List<({int masterId, List<DbCapturedImage> subs, String? runId})>
      calls = [];

  @override
  Future<MasterAccumulateResult> addNight({
    required int masterId,
    required List<DbCapturedImage> subs,
    required String label,
    IntegrationSettings settings = IntegrationSettings.defaults,
    String? biasPath,
    String? runId,
    bool allowRestart = true,
  }) async {
    calls.add((masterId: masterId, subs: subs, runId: runId));
    return MasterAccumulateResult(
      sidecarPath: '/sidecar_$masterId.skmaster',
      masterPath: null,
      previewPath: null,
      frameCount: subs.length,
      totalIntegrationSec:
          subs.fold<double>(0, (a, s) => a + s.exposureDuration),
      width: 100,
      height: 80,
      channels: 1,
      framesAdded: subs.length,
      rejected: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

/// Fake batch-integration service that records the subs it integrates and
/// produces one outcome per filter bucket (mirroring the real fan-out).
class _FakeIntegrationService implements PostSessionIntegrationService {
  final List<List<DbCapturedImage>> calls = [];
  final List<String?> runIds = [];

  @override
  Future<List<PostSessionIntegrationOutcome>> integrate({
    required List<DbCapturedImage> subs,
    required IntegrationSettings settings,
    required String Function(String filterBucket) outputFitsPathBuilder,
    int? targetId,
    String? targetName,
    String? biasPath,
    ResolvedCalibration? pinnedCalibration,
    bool generatePreview = true,
    double? hintRaHours,
    double? hintDecDegrees,
    String? runId,
    int? sessionId,
    int plannedDrafts = 0,
    bool closePass = true,
    String? passTitle,
  }) async {
    calls.add(subs);
    runIds.add(runId);
    // Group by trimmed filter, one outcome per bucket — the real service's
    // contract — so the caller's per-filter accounting is exercised honestly.
    final byBucket = <String, List<DbCapturedImage>>{};
    for (final s in subs) {
      final b = (s.filter ?? '').trim();
      byBucket.putIfAbsent(b.isEmpty ? '(none)' : b, () => []).add(s);
    }
    var id = 1000;
    return [
      for (final e in byBucket.entries)
        PostSessionIntegrationOutcome(
          masterId: id++,
          filter: e.key == '(none)' ? null : e.key,
          result: IntegrateSessionResult(
            masterFitsPath: outputFitsPathBuilder(e.key),
            previewPath: null,
            rejectionMapPath: null,
            framesIntegrated: e.value.length,
            framesRejected: 0,
            totalIntegrationSec:
                e.value.fold<double>(0, (a, s) => a + s.exposureDuration),
            rmsResidual: 0.0,
            width: 100,
            height: 80,
            channels: 1,
            perFrameStats: const [],
          ),
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

/// A Darkroom seam the stub autopilot never reaches. Present so the stub can be
/// constructed; a call here is a test wiring error, not a runtime path.
class _UnusedDarkroom implements DarkroomSeam {
  const _UnusedDarkroom();

  Never _unused(String call) =>
      throw StateError('the stub autopilot reached the Darkroom seam ($call)');

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async =>
      _unused('validate');

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async =>
      _unused('renderPreview');

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async =>
      _unused('renderExport');

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async =>
      _unused('registry');

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async =>
      _unused('cancel');
}

class _UnusedNotifier implements DawnMorningNotifier {
  const _UnusedNotifier();

  @override
  Future<DawnNotificationDecision> announce(DawnJobReport report) async =>
      throw StateError('the stub autopilot reached the morning notifier');
}

class _UnusedTransport implements ArtifactTransport {
  const _UnusedTransport();

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async =>
      throw StateError('the stub autopilot reached delivery');

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async =>
      throw StateError('the stub autopilot reached delivery');

  @override
  Future<void> close() async {}
}

/// Records which sessions the run-completion path handed to the Darkroom pass.
class _StubDawnAutopilot extends DawnAutopilotService {
  _StubDawnAutopilot(SkotiqDatabase db)
      : super(
          jobs: DarkroomJobsDao(db),
          recipes: RecipesDao(db),
          masters: IntegratedMastersDao(db),
          targets: TargetsDao(db),
          resolver: DawnMasterResolver(
            images: ImagesDao(db),
            masters: IntegratedMastersDao(db),
          ),
          drafts: const DawnDraftBuilder(darkroom: _UnusedDarkroom()),
          darkroom: const _UnusedDarkroom(),
          photometry: DawnPhotometryResolver(
            coneSearch: (centre, radius, {maxMagnitude}) async => const [],
          ),
          delivery: DeliveryService(
            targets: DeliveryTargetsDao(db),
            journal: DeliveryJournalDao(db),
            transportFactory: (destination, jobId) => const _UnusedTransport(),
          ),
          notifier: const _UnusedNotifier(),
          outputDirectory: _refuse,
        );

  static Future<String> _refuse() async =>
      throw StateError('the stub autopilot resolved an output directory');

  final List<int> sessions = [];

  @override
  Future<DawnJobOutcome> runDawnForSession(int sessionId) async {
    sessions.add(sessionId);
    return const DawnJobOutcome(
      jobId: 7,
      state: DarkroomJobState.done,
      report: null,
      reportPath: null,
      failure: null,
    );
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _RecordingAutoIntegrationService extends AutoIntegrationService {
  _RecordingAutoIntegrationService(super.ref);

  final calls = <int>[];

  @override
  Future<AutoIntegrationResult> maybeRunForSession(int sessionId) async {
    calls.add(sessionId);
    return const AutoIntegrationResult(ran: true, message: 'ready');
  }
}

void main() {
  late SkotiqDatabase db;
  late _FakeAccumulationService accumulate;
  late _FakeIntegrationService integrate;
  late _StubDawnAutopilot darkroom;
  late PushNotificationService push;
  late List<PushNotification> pushes;
  late StreamSubscription<PushNotification> pushSubscription;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    accumulate = _FakeAccumulationService();
    integrate = _FakeIntegrationService();
    darkroom = _StubDawnAutopilot(db);
    push = PushNotificationService();
    pushes = <PushNotification>[];
    pushSubscription = push.notifications.listen(pushes.add);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      masterAccumulationServiceProvider.overrideWithValue(accumulate),
      postSessionIntegrationServiceProvider.overrideWithValue(integrate),
      dawnAutopilotServiceProvider.overrideWithValue(darkroom),
      pushNotificationServiceProvider.overrideWithValue(push),
    ]);
  });

  tearDown(() async {
    await pushSubscription.cancel();
    container.dispose();
    await db.close();
  });

  Future<void> enableAutoIntegrate() async {
    await db.settingsDao.setSetting(kAutoIntegrateSettingKey, 'true');
  }

  Future<int> insertSession() {
    return db.into(db.imagingSessions).insert(
          ImagingSessionsCompanion.insert(startTime: DateTime.now()),
        );
  }

  Future<int> insertTarget(String name) {
    return db.into(db.targets).insert(
          TargetsCompanion.insert(name: name, ra: 1.0, dec: 2.0),
        );
  }

  Future<int> insertSub({
    required int sessionId,
    int? targetId,
    required String filter,
    bool accepted = true,
  }) {
    final stamp = DateTime.now().microsecondsSinceEpoch +
        filter.hashCode +
        (accepted ? 0 : 1);
    return db.into(db.capturedImages).insert(
          CapturedImagesCompanion.insert(
            filePath: '/l/${filter}_$stamp.fits',
            fileName: '${filter}_$stamp.fits',
            frameType: const Value('light'),
            exposureDuration: 120.0,
            capturedAt: DateTime.now(),
            sessionId: Value(sessionId),
            targetId: Value(targetId),
            gain: const Value(100),
            offset: const Value(10),
            binX: const Value(1),
            binY: const Value(1),
            filter: Value(filter),
            isAccepted: Value(accepted),
          ),
        );
  }

  Future<int> insertAccumulatingMaster({
    required int targetId,
    required String filter,
  }) {
    return IntegratedMastersDao(db).insertMaster(
      targetId: targetId,
      name: 'M-$filter',
      sidecarPath: '/sidecar_$filter.skmaster',
      status: IntegratedMasterStatus.accumulating,
      accumulationMode: AccumulationMode.runningWeightedMean,
      filter: filter,
    );
  }

  test('disabled setting is a clean no-op', () async {
    final service = container.read(autoIntegrationServiceProvider);
    final result = await service.maybeRunForSession(1);
    expect(result.ran, isFalse);
    expect(accumulate.calls, isEmpty);
    expect(integrate.calls, isEmpty);
  });

  test(
      'REGRESSION #6: a multi-filter night with an accumulating master for ONE '
      'filter still integrates every other filter (no silent drop)', () async {
    await enableAutoIntegrate();
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');

    // Accumulating master exists for L only.
    final lMaster =
        await insertAccumulatingMaster(targetId: targetId, filter: 'L');

    // Night: 3×L (dominant, has a master), 2×Ha, 1×OIII (no masters).
    for (var i = 0; i < 3; i++) {
      await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');
    }
    for (var i = 0; i < 2; i++) {
      await insertSub(sessionId: sessionId, targetId: targetId, filter: 'Ha');
    }
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'OIII');

    final service = container.read(autoIntegrationServiceProvider);
    final result = await service.maybeRunForSession(sessionId);

    expect(result.ran, isTrue);

    // The 3 L subs were folded into the existing accumulating master.
    expect(accumulate.calls, hasLength(1));
    expect(accumulate.calls.single.masterId, lMaster);
    expect(accumulate.calls.single.subs, hasLength(3));

    // The non-dominant Ha + OIII subs were NOT dropped — they were batch
    // integrated (3 subs across two filter buckets).
    expect(integrate.calls, hasLength(1));
    final batched = integrate.calls.single;
    expect(batched, hasLength(3));
    expect(batched.map((s) => (s.filter ?? '').trim()).toSet(), {'Ha', 'OIII'});

    // The toast reports the TOTAL across all filters: 3 (folded) + 3 (batch).
    expect(result.message, contains('6 subs'));
  });

  test('no accumulating master anywhere → every filter is batch-integrated',
      () async {
    await enableAutoIntegrate();
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');

    for (var i = 0; i < 2; i++) {
      await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');
    }
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'Ha');

    final service = container.read(autoIntegrationServiceProvider);
    final result = await service.maybeRunForSession(sessionId);

    expect(result.ran, isTrue);
    expect(accumulate.calls, isEmpty);
    expect(integrate.calls, hasLength(1));
    // All three subs (both filters) reach the batch integrator.
    expect(integrate.calls.single, hasLength(3));
    expect(result.message, contains('3 subs'));
  });

  test('accumulating masters for EVERY filter fold all of them (no batch run)',
      () async {
    await enableAutoIntegrate();
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');
    final lMaster =
        await insertAccumulatingMaster(targetId: targetId, filter: 'L');
    final haMaster =
        await insertAccumulatingMaster(targetId: targetId, filter: 'Ha');

    for (var i = 0; i < 2; i++) {
      await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');
    }
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'Ha');

    final service = container.read(autoIntegrationServiceProvider);
    final result = await service.maybeRunForSession(sessionId);

    expect(result.ran, isTrue);
    // Two folds (one per filter), no batch run.
    expect(accumulate.calls, hasLength(2));
    expect(integrate.calls, isEmpty);
    final folded = {
      for (final c in accumulate.calls) c.masterId: c.subs.length
    };
    expect(folded[lMaster], 2);
    expect(folded[haMaster], 1);
    // Total reported across both folds.
    expect(result.message, contains('3 subs'));
  });

  test('whitespace-padded filter names fold into the same bucket (no drop)',
      () async {
    await enableAutoIntegrate();
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');
    final lMaster =
        await insertAccumulatingMaster(targetId: targetId, filter: 'L');

    // Two L subs, one with a trailing space — they must NOT fragment into a
    // separate bucket that gets routed differently.
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L ');

    final service = container.read(autoIntegrationServiceProvider);
    final result = await service.maybeRunForSession(sessionId);

    expect(result.ran, isTrue);
    // Both subs folded into the one L master; nothing spilled to a batch run.
    expect(accumulate.calls, hasLength(1));
    expect(accumulate.calls.single.masterId, lMaster);
    expect(accumulate.calls.single.subs, hasLength(2));
    expect(integrate.calls, isEmpty);
    expect(result.message, contains('2 subs'));
  });

  test('host coordinator runs independently of the sequencer screen', () async {
    late _RecordingAutoIntegrationService recording;
    final coordinatorContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, FfiBackend(database: db)),
        ),
        autoIntegrationServiceProvider.overrideWith((ref) {
          recording = _RecordingAutoIntegrationService(ref);
          return recording;
        }),
      ],
    );
    addTearDown(coordinatorContainer.dispose);

    coordinatorContainer.read(autoIntegrationCoordinatorProvider);
    coordinatorContainer
        .read(sequenceTerminalRunResultProvider.notifier)
        .state = const SequenceTerminalRunResult(
      generation: 1,
      outcome: SequenceExecutionState.completed,
      runStatus: 'completed',
      runId: 10,
      dbSessionId: 20,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(recording.calls, [20]);
    expect(
      coordinatorContainer.read(autoIntegrationCompletionProvider)?.generation,
      1,
    );

    coordinatorContainer
        .read(sequenceTerminalRunResultProvider.notifier)
        .state = const SequenceTerminalRunResult(
      generation: 2,
      outcome: SequenceExecutionState.idle,
      runStatus: 'stopped',
      runId: 11,
      dbSessionId: 21,
    );
    await Future<void>.delayed(Duration.zero);
    expect(recording.calls, [20],
        reason: 'Stopped runs must not auto-integrate');
  });

  test('every native integration call carries the session\'s cancel handle',
      () async {
    await enableAutoIntegrate();
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');
    final lMaster =
        await insertAccumulatingMaster(targetId: targetId, filter: 'L');
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'Ha');

    await container
        .read(autoIntegrationServiceProvider)
        .maybeRunForSession(sessionId);

    final handle = AutoIntegrationService.integrationRunIdFor(sessionId);
    expect(accumulate.calls.single.masterId, lMaster);
    expect(accumulate.calls.single.runId, handle);
    expect(integrate.runIds, [handle],
        reason: 'a run with no handle cannot be stopped by safing');
  });

  test(
      'the run-completion path hands the night to the Darkroom pass, which '
      'owns the morning message', () async {
    await enableAutoIntegrate();
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');

    final result = await container
        .read(autoIntegrationServiceProvider)
        .maybeRunForSession(sessionId);
    await Future<void>.delayed(Duration.zero);

    expect(result.ran, isTrue);
    expect(darkroom.sessions, [sessionId]);
    expect(result.darkroom, isNotNull);
    expect(result.darkroomSkippedReason, isNull);
    expect(
      pushes.where((p) => p.eventType == 'PostSessionMasterReady'),
      isEmpty,
      reason: 'the Darkroom pass sends the morning report, so the integration '
          'half must not announce the same night a second time',
    );
  });

  test('with the Darkroom draft switched off the run says so and still pushes',
      () async {
    await enableAutoIntegrate();
    await db.settingsDao.setSetting(kDarkroomAutoDraftSettingKey, 'false');
    final sessionId = await insertSession();
    final targetId = await insertTarget('M42');
    await insertSub(sessionId: sessionId, targetId: targetId, filter: 'L');

    final result = await container
        .read(autoIntegrationServiceProvider)
        .maybeRunForSession(sessionId);
    await Future<void>.delayed(Duration.zero);

    expect(result.ran, isTrue);
    expect(darkroom.sessions, isEmpty);
    expect(result.darkroom, isNull);
    expect(result.darkroomSkippedReason, contains('switched off'));
    expect(
      pushes.where((p) => p.eventType == 'PostSessionMasterReady'),
      hasLength(1),
      reason:
          'with no Darkroom pass to announce the night, the integration half '
          'keeps its own push',
    );
  });

  test('remote clients neither process local data nor store the host setting',
      () async {
    final backend = _MockNetworkBackend();
    when(backend.getAutoIntegrationEnabled).thenAnswer((_) async => true);
    when(
      () => backend.setAutoIntegrationEnabled(any()),
    ).thenAnswer((_) async {});

    late _RecordingAutoIntegrationService recording;
    final remoteContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        autoIntegrationServiceProvider.overrideWith((ref) {
          recording = _RecordingAutoIntegrationService(ref);
          return recording;
        }),
      ],
    );
    addTearDown(remoteContainer.dispose);
    remoteContainer.read(autoIntegrationServiceProvider);

    expect(await remoteContainer.read(autoIntegrationEnabledProvider.future),
        isTrue);
    await remoteContainer
        .read(autoIntegrationSettingsActionsProvider)
        .setEnabled(false);
    verify(() => backend.setAutoIntegrationEnabled(false)).called(1);
    expect(
      await db.settingsDao.getSetting(kAutoIntegrateSettingKey),
      isNull,
    );

    remoteContainer.read(autoIntegrationCoordinatorProvider);
    remoteContainer.read(sequenceTerminalRunResultProvider.notifier).state =
        const SequenceTerminalRunResult(
      generation: 1,
      outcome: SequenceExecutionState.completed,
      runStatus: 'completed',
      runId: 1,
      dbSessionId: 2,
    );
    await Future<void>.delayed(Duration.zero);
    expect(recording.calls, isEmpty);
  });

  // D2-4. A fresh install shipped "Draft, deliver and report at dawn" reading
  // [ON] on the Darkroom autopilot page while the row directly beneath it read
  // "Auto-integrate has to be on for any of this to run ... It is currently
  // off". Absent-means-on was the reason: the row nobody has written answered
  // on for a machine where the pass could not run at all. The absent value now
  // follows the prerequisite; an explicit value is still the operator's.
  group('the absent Darkroom draft row follows its prerequisite', () {
    Future<bool> read() => container
        .read(autoIntegrationServiceProvider)
        .isDarkroomAutoDraftEnabled();

    test('a fresh install reports it off, because the pass cannot run',
        () async {
      expect(await db.settingsDao.getSetting(kAutoIntegrateSettingKey), isNull);
      expect(await db.settingsDao.getSetting(kDarkroomAutoDraftSettingKey),
          isNull);
      expect(await read(), isFalse);
    });

    test('turning the prerequisite on arms the untouched switch', () async {
      await enableAutoIntegrate();
      expect(await read(), isTrue,
          reason: 'a rig that integrates all night and then declines to draft '
              'is the surprising behaviour this default exists to avoid');
    });

    test('an explicit value is read back as written, either way', () async {
      await db.settingsDao.setSetting(kDarkroomAutoDraftSettingKey, 'false');
      await enableAutoIntegrate();
      expect(await read(), isFalse,
          reason: 'the operator turned it off; another page must not turn it '
              'back on');

      await db.settingsDao.setSetting(kAutoIntegrateSettingKey, 'false');
      await db.settingsDao.setSetting(kDarkroomAutoDraftSettingKey, 'true');
      expect(await read(), isTrue);
    });
  });
}
