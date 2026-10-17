// Coordinator-level tests for the dawn autopilot: the durable job that turns a
// night's linear masters into a first draft, a morning report and a delivery.
//
// The Darkroom FFI entry points are behind [DarkroomSeam], so every decision
// the autopilot makes — which steps enter the draft, when the background fit is
// retried, whether the colour step survives its full-resolution proof, what the
// morning report says — runs here without the Rust library. The database is
// real: job state transitions, recipe rows and the delivery journal are what the
// pipeline is judged on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show UpdateKind, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// A Darkroom seam whose every reply the test writes.
class _ScriptedDarkroom implements DarkroomSeam {
  _ScriptedDarkroom({required this.baseMasterRef});

  final String baseMasterRef;

  /// Steps the registry's draft carries, in registry order.
  List<Map<String, dynamic>> draftSteps = [
    {
      'opId': 'crop',
      'opVersion': 1,
      'params': <String, dynamic>{},
      'enabled': true,
    },
    {
      'opId': 'background_extract',
      'opVersion': 1,
      'params': <String, dynamic>{},
      'enabled': true,
    },
    {
      'opId': 'stretch',
      'opVersion': 1,
      'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
      'enabled': true,
    },
  ];

  /// Notes the registry's draft carries.
  List<Map<String, dynamic>> draftNotes = [];

  /// Step indices the next preview reports as skipped, with the reason.
  Map<int, String> skipReasons = {};

  /// Per-channel scales the preview reports as a step's own measurement, the
  /// way `color_calibrate@1` reports the balance it fitted.
  Map<int, List<double>> channelScales = {};

  /// The auto stretch parameters a `screen`-encoded preview reports having
  /// applied for display. The draft reads them as the measurement over the
  /// prefix it just rendered.
  Map<String, dynamic>? screenTransfer;

  /// When set, the next preview throws this instead of answering.
  Object? previewError;

  /// When set, a `screen`-encoded preview throws this instead of answering, so
  /// a test can fail the stretch re-measurement alone.
  Object? screenPreviewError;

  /// When set, the next export throws this instead of writing.
  Object? exportError;

  /// Whether the registry answers at all.
  bool registryAnswers = true;

  /// Runs before each preview, so a test can cancel mid-pipeline.
  Future<void> Function()? beforePreview;

  /// Runs before each registry call.
  Future<void> Function()? beforeRegistry;

  /// Errors the registry raises for a given `masterPath`, so a multi-master
  /// test can fail exactly one master no matter what order they resolve in.
  Map<String, Object> registryErrors = {};

  /// Runs after each export, with the export's own args — the hook a test uses
  /// to change the world between the draft and delivery.
  Future<void> Function(Map<String, dynamic> args)? afterExport;

  final List<Map<String, dynamic>> registryCalls = [];
  final List<Map<String, dynamic>> previewContexts = [];
  final List<String> previewRecipes = [];
  final List<Map<String, dynamic>> exportArgs = [];
  final List<Map<String, dynamic>> cancelArgs = [];

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    await beforeRegistry?.call();
    registryCalls.add(args);
    final scripted = registryErrors[args['masterPath']];
    if (scripted != null) throw scripted;
    if (!registryAnswers) return {'schemaVersion': 1, 'ops': <dynamic>[]};
    return {
      'schemaVersion': 1,
      'ops': <dynamic>[],
      'draft': {
        'recipe': {
          'id': args['recipeId'],
          'schemaVersion': 1,
          'baseMasterRef': baseMasterRef,
          'createdBy': 'autopilot',
          'steps': draftSteps,
        },
        'notes': draftNotes,
        'autoParams': <String, dynamic>{},
      },
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    await beforePreview?.call();
    previewContexts.add(context);
    previewRecipes.add(recipeJson);
    final screen = context['encoding'] == 'screen';
    final error = screen ? (screenPreviewError ?? previewError) : previewError;
    if (error != null) {
      if (identical(error, screenPreviewError)) {
        screenPreviewError = null;
      } else {
        previewError = null;
      }
      throw error;
    }
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    final stop = context['stopAfter'];
    final last = stop is int ? stop : steps.length - 1;
    return DarkroomRenderedPreview(
      width: 4,
      height: 4,
      isColor: false,
      rgba: Uint8List(4 * 4 * 4),
      report: {
        'report': {
          'steps': [
            for (var i = 0; i <= last && i < steps.length; i++)
              {
                'index': i,
                'opId': (steps[i] as Map<String, dynamic>)['opId'],
                'opVersion': 1,
                'outcome': skipReasons.containsKey(i) ? 'skipped' : 'applied',
                if (skipReasons.containsKey(i)) 'reason': skipReasons[i],
                if (!skipReasons.containsKey(i) && channelScales.containsKey(i))
                  'measured': {
                    'source': 'solved',
                    'channelScale': channelScales[i],
                  },
              },
          ],
        },
        if (screen)
          'encoding': {
            'requested': 'screen',
            'applied': 'screen',
            'sourceDomain': 'linear',
            'screenTransferAffectsRecipe': false,
            'screenTransfer': screenTransfer,
          },
      },
    );
  }

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async {
    exportArgs.add(args);
    final error = exportError;
    if (error != null) {
      exportError = null;
      throw error;
    }
    final outputs = args['outputs'] as List;
    for (final output in outputs) {
      final path = (output as Map<String, dynamic>)['path'] as String;
      await File(path).writeAsBytes(const [0xFF, 0xD8, 0xFF, 0xD9]);
    }
    await afterExport?.call(args);
    return {'stage': 'final', 'outputs': outputs};
  }

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    return {'ok': true, 'error': null, 'steps': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async {
    cancelArgs.add(args);
    return {
      'renderId': args['renderId'],
      'op': args['op'],
      'running': true,
      'cancelRequested': true,
    };
  }
}

/// A notifier that records what it was asked to announce.
class _RecordingNotifier implements DawnMorningNotifier {
  final List<DawnJobReport> announced = [];
  DawnNotificationDecision decision = const DawnNotificationDecision(
    sent: true,
    reason: 'Sent through the notification router.',
  );

  @override
  Future<DawnNotificationDecision> announce(DawnJobReport report) async {
    announced.add(report);
    return decision;
  }
}

/// A transport that accepts everything and records what it was handed, so a
/// test can read the exact file list that reached a destination.
class _RecordingTransport implements ArtifactTransport {
  _RecordingTransport(this.delivered);

  /// Absolute source paths, in the order delivery offered them.
  final List<String> delivered;

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {}

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    delivered.add(artifact.sourcePath);
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: artifact.checksum,
      destinationDescription: 'the recording destination',
    );
  }

  @override
  Future<void> close() async {}
}

/// A free-space probe that always reports room.
///
/// Only so a real [WatchedFolderTransport] can be used in a test without the
/// test's verdict depending on how full the machine's temp filesystem is.
class _AmpleSpace implements FreeSpaceProbe {
  const _AmpleSpace();

  @override
  Future<int> freeBytes(String path) async => 1 << 40;
}

/// A jobs DAO that can refuse a state write a set number of times, the way a
/// database held by another writer refuses one.
class _FlakyJobsDao extends DarkroomJobsDao {
  _FlakyJobsDao(super.db);

  /// How many `markFailed` calls are refused before one is let through.
  int refuseFailedWrites = 0;

  /// How many `markDone` calls are refused before one is let through.
  int refuseDoneWrites = 0;

  /// Job ids whose `markRunning` throws outright, so `runJob` itself raises.
  final Set<int> refuseToStart = <int>{};

  int failedWriteAttempts = 0;

  @override
  Future<DarkroomJob> markRunning(int id, {DateTime? now}) {
    if (refuseToStart.contains(id)) {
      throw StateError('the database refused to start job $id');
    }
    return super.markRunning(id, now: now);
  }

  @override
  Future<DarkroomJob> markFailed(int id, String errorText, {DateTime? now}) {
    failedWriteAttempts++;
    if (refuseFailedWrites > 0) {
      refuseFailedWrites--;
      throw StateError('database is locked');
    }
    return super.markFailed(id, errorText, now: now);
  }

  @override
  Future<DarkroomJob> markDone(int id, {String? note, DateTime? now}) {
    if (refuseDoneWrites > 0) {
      refuseDoneWrites--;
      throw StateError('database is locked');
    }
    return super.markDone(id, note: note, now: now);
  }
}

/// A transport that refuses every destination, so delivery reports a problem
/// while the job keeps its drafts.
/// Accepts the first file and raises the operator's stop while doing it, so
/// the cancellation lands INSIDE the delivery loop rather than before it.
class _StopAfterFirstFileTransport implements ArtifactTransport {
  _StopAfterFirstFileTransport({required this.onFirstFile});

  final Future<void> Function() onFirstFile;
  final List<String> delivered = [];

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {}

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    delivered.add(artifact.fileName);
    if (delivered.length == 1) await onFirstFile();
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: artifact.checksum,
      destinationDescription: 'test://${artifact.fileName}',
    );
  }

  @override
  Future<void> close() async {}
}

class _RefusingTransport implements ArtifactTransport {
  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {
    throw const DeliveryFailure(
      DeliveryFailureKind.destinationUnreachable,
      'the office PC did not answer',
    );
  }

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    throw const DeliveryFailure(
      DeliveryFailureKind.destinationUnreachable,
      'the office PC did not answer',
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  late SkotiqDatabase db;
  late Directory workspace;
  late Directory output;
  late _ScriptedDarkroom darkroom;
  late _RecordingNotifier notifier;
  late String masterPath;

  Future<int> insertSession() => db
      .into(db.imagingSessions)
      .insert(ImagingSessionsCompanion.insert(startTime: DateTime.now()));

  Future<int> insertTarget(String name) => db
      .into(db.targets)
      .insert(TargetsCompanion.insert(name: name, ra: 1.0, dec: 2.0));

  Future<int> insertSub({required int sessionId, int? targetId}) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: '/l/$stamp.fits',
            fileName: '$stamp.fits',
            frameType: const Value('light'),
            exposureDuration: 120.0,
            capturedAt: DateTime.now(),
            sessionId: Value(sessionId),
            targetId: Value(targetId),
            isAccepted: const Value(true),
          ),
        );
  }

  /// A finalized master on disk, folded from [imageIds].
  Future<int> insertMaster({
    required List<int> imageIds,
    int? targetId,
    String? filter,
    int channels = 1,
    String statsJson = '{}',
    String? path,
    bool solved = false,
  }) async {
    final file = File(path ?? masterPath);
    await file.writeAsString('linear master');
    final masters = IntegratedMastersDao(db);
    final id = await masters.insertMaster(
      targetId: targetId,
      name: filter == null ? 'M42' : 'M42 · $filter',
      masterFitsPath: path ?? masterPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: channels,
      width: 100,
      height: 80,
      frameCount: imageIds.length,
      totalIntegrationSeconds: 3600.0,
      filter: filter,
      statsJson: statsJson,
    );
    if (solved) {
      await masters.updateWcs(
        id,
        crval1: 83.8,
        crval2: -5.4,
        crpix1: 50.0,
        crpix2: 40.0,
        cd1_1: -2.8e-4,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: 2.8e-4,
      );
    }
    for (final imageId in imageIds) {
      await masters.recordFoldedFrame(
        masterId: id,
        imageId: imageId,
        accepted: true,
      );
    }
    return id;
  }

  DawnAutopilotService buildService({
    ArtifactTransportFactory? transportFactory,
    List<Star> catalog = const [],
    DarkroomJobsDao? jobs,
    LoggingService? logger,
  }) {
    return DawnAutopilotService(
      logger: logger,
      jobs: jobs ?? DarkroomJobsDao(db),
      recipes: RecipesDao(db),
      masters: IntegratedMastersDao(db),
      targets: TargetsDao(db),
      resolver: DawnMasterResolver(
        images: ImagesDao(db),
        masters: IntegratedMastersDao(db),
      ),
      drafts: DawnDraftBuilder(darkroom: darkroom),
      darkroom: darkroom,
      photometry: DawnPhotometryResolver(
        coneSearch: (centre, radius, {maxMagnitude}) async => catalog,
      ),
      delivery: DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory:
            transportFactory ?? (destination, jobId) => _RefusingTransport(),
      ),
      notifier: notifier,
      outputDirectory: () async => output.path,
    );
  }

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    workspace = await Directory.systemTemp.createTemp('dawn-autopilot');
    output = Directory('${workspace.path}/out')..createSync(recursive: true);
    masterPath = '${workspace.path}/M42_master.fits';
    darkroom = _ScriptedDarkroom(baseMasterRef: masterPath);
    notifier = _RecordingNotifier();
  });

  tearDown(() async {
    await db.close();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test(
    'a dawn job drafts, persists the recipe, renders it and finishes done',
    () async {
      final sessionId = await insertSession();
      final targetId = await insertTarget('M42');
      final imageId = await insertSub(sessionId: sessionId, targetId: targetId);
      final masterId = await insertMaster(
        imageIds: [imageId],
        targetId: targetId,
        statsJson: jsonEncode({
          'framesIntegrated': 30,
          'framesRejected': 4,
          'totalIntegrationSec': 3600.0,
        }),
      );

      final outcome = await buildService().runDawnForSession(sessionId);

      expect(outcome.succeeded, isTrue);
      final job = await DarkroomJobsDao(db).getById(outcome.jobId);
      expect(job!.state, DarkroomJobState.done);
      expect(job.kind, DarkroomJobKind.dawn);
      expect(job.progress, 1.0);
      expect(job.note, contains('1 draft ready'));

      final recipes = await RecipesDao(db).listForMaster(masterPath);
      expect(recipes, hasLength(1));
      expect(recipes.single.createdBy, RecipeAuthor.autopilot);
      expect(recipes.single.masterId, masterId);
      expect(recipes.single.sessionId, sessionId);
      final steps = jsonDecode(recipes.single.stepsJson) as List;
      expect(steps.map((s) => (s as Map)['opId']), [
        'crop',
        'background_extract',
        'stretch',
      ]);

      // The draft image was exported under the job's own cancellation id, with
      // the recipe sidecar beside it.
      expect(darkroom.exportArgs, hasLength(1));
      expect(
        darkroom.exportArgs.single['renderId'],
        DawnAutopilotService.renderIdFor(outcome.jobId),
      );
      expect(darkroom.exportArgs.single['sidecarPath'], endsWith('.skrecipe'));
      expect(
        File(outcome.report!.masters.single.draftRenderPath!).existsSync(),
        isTrue,
      );

      // The morning report reads the frames out of the master's own row.
      expect(outcome.report!.framesUsed, 30);
      expect(outcome.report!.framesRejected, 4);
      expect(outcome.reportPath, isNotNull);
      expect(File(outcome.reportPath!).existsSync(), isTrue);
    },
  );

  test(
    'a mono master carries no colour step and the report says why',
    () async {
      darkroom.draftNotes = [
        {
          'opId': 'color_calibrate',
          'outcome': 'omitted',
          'reason': 'this master has 1 channel(s); the colour fit needs three',
        },
      ];
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);

      final outcome = await buildService().runDawnForSession(sessionId);

      final draft = outcome.report!.masters.single.draft!;
      expect(draft.indexOfOp('color_calibrate'), -1);
      expect(
        draft.notes.firstWhere((n) => n.opId == 'color_calibrate').reason,
        contains('needs three'),
      );

      // And the row carries the same account, not only the report on disk.
      // The editor never opens the report, so a draft whose reasons lived
      // there alone arrived in the Darkroom with them stripped off.
      final recipes = RecipesDao(db);
      final row = (await recipes.listForMaster(masterPath)).single;
      final stored = await recipes.draftNotesOf(row.id!);
      expect(
        stored.firstWhere((n) => n.opId == 'color_calibrate').reason,
        contains('needs three'),
      );
      expect(
        stored.map((n) => n.opId),
        containsAll(draft.notes.map((n) => n.opId)),
        reason: 'the row records every decision the pass made',
      );
    },
  );

  test('a superseding re-run replaces the account it wrote last time', () async {
    darkroom.draftNotes = [
      {
        'opId': 'color_calibrate',
        'outcome': 'omitted',
        'reason': 'this master has 1 channel(s); the colour fit needs three',
      },
    ];
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    final recipes = RecipesDao(db);

    await buildService().runDawnForSession(sessionId);
    final first = (await recipes.listForMaster(masterPath)).single;
    expect(
      (await recipes.draftNotesOf(first.id!)).map((n) => n.opId),
      contains('color_calibrate'),
    );

    // The resumed attempt measures a draft that leaves nothing out. The row is
    // rewritten, so its account has to be this pass's — a stale omission would
    // explain a step the stack no longer misses.
    darkroom.draftNotes = [];
    await buildService().runDawnForSession(sessionId);
    final rows = await recipes.listForMaster(masterPath);
    expect(rows, hasLength(1));
    expect(
      (await recipes.draftNotesOf(
        rows.single.id!,
      )).where((n) => n.outcome == 'omitted'),
      isEmpty,
    );
  });

  test(
    'an RGB master keeps the colour step once it applies at level 0',
    () async {
      darkroom.draftSteps = [
        {
          'opId': 'background_extract',
          'opVersion': 1,
          'params': <String, dynamic>{},
          'enabled': true,
        },
        {
          'opId': 'color_calibrate',
          'opVersion': 1,
          'params': <String, dynamic>{},
          'enabled': true,
        },
        {
          'opId': 'stretch',
          'opVersion': 1,
          'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
          'enabled': true,
        },
      ];
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId], channels: 3, solved: true);

      final outcome = await buildService(
        catalog: [
          Star(
            id: 'a',
            name: 'a',
            coordinates: const CelestialCoordinate(ra: 83.8 / 15.0, dec: -5.4),
            magnitude: 9.0,
            colorIndex: 0.6,
          ),
        ],
      ).runDawnForSession(sessionId);

      final draft = outcome.report!.masters.single.draft!;
      expect(draft.indexOfOp('color_calibrate'), 1);
      // The proof render ran at full resolution, stopping at the colour step,
      // with the catalogue attached.
      final proof = darkroom.previewContexts.single;
      expect(proof['level'], 0);
      expect(proof['stopAfter'], 1);
      expect((proof['catalogStars'] as List), hasLength(1));
      expect(
        draft.notes.firstWhere((n) => n.opId == 'color_calibrate').outcome,
        'included',
      );
      // This render reported no fitted scales, so nothing is pinned and the
      // note says the step re-solves on every render rather than implying a
      // preview will match this proof.
      expect(
        (draft.steps[1]['params'] as Map).containsKey('channelScale'),
        isFalse,
      );
      expect(
        draft.notes.firstWhere((n) => n.opId == 'color_calibrate').reason,
        contains('no fitted channel scales'),
      );
    },
  );

  test('the draft pins the channel scales the proof render fitted', () async {
    darkroom.draftSteps = [
      {
        'opId': 'background_extract',
        'opVersion': 1,
        'params': <String, dynamic>{},
        'enabled': true,
      },
      {
        'opId': 'color_calibrate',
        'opVersion': 1,
        'params': <String, dynamic>{},
        'enabled': true,
      },
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
    ];
    darkroom.channelScales = {
      1: [1.25, 1.0, 0.8125],
    };
    darkroom.screenTransfer = {
      'blackPoint': 812.5,
      'whitePoint': 4200.0,
      'd': 2.75,
      'b': 0.0,
      'symmetryPoint': 0.0,
    };
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId], channels: 3, solved: true);

    final outcome = await buildService(
      catalog: [
        const Star(
          id: 'a',
          name: 'a',
          coordinates: CelestialCoordinate(ra: 83.8 / 15.0, dec: -5.4),
          magnitude: 9.0,
          colorIndex: 0.6,
        ),
      ],
    ).runDawnForSession(sessionId);

    final draft = outcome.report!.masters.single.draft!;
    expect((draft.steps[1]['params'] as Map)['channelScale'], [
      1.25,
      1.0,
      0.8125,
    ]);
    expect(
      draft.notes.firstWhere((n) => n.opId == 'color_calibrate').reason,
      contains('1.2500'),
    );

    // The pinned scales are in the recipe that was persisted, not only in the
    // report: the editor opens the row, and a preview at a coarse level replays
    // the balance from there.
    final recipes = await RecipesDao(db).listForMaster(masterPath);
    final persisted = jsonDecode(recipes.single.stepsJson) as List;
    expect(((persisted[1] as Map)['params'] as Map)['channelScale'], [
      1.25,
      1.0,
      0.8125,
    ]);

    // Pinning changes the pixels under the stretch — the registry measured with
    // the colour step skipping — so the stretch is measured again over the
    // final stack, and the recipe carries that fit.
    expect(darkroom.previewContexts, hasLength(2));
    final remeasure = darkroom.previewContexts.last;
    expect(remeasure['encoding'], 'screen');
    expect(remeasure['stopAfter'], 1);
    expect(remeasure['maxDimension'], kDraftMeasureMaxDimension);
    expect(
      jsonDecode(darkroom.previewRecipes.last),
      containsPair(
        'steps',
        contains(
          containsPair(
            'params',
            containsPair('channelScale', [1.25, 1.0, 0.8125]),
          ),
        ),
      ),
      reason: 're-measuring must render the prefix the draft actually carries',
    );
    expect((persisted[2] as Map)['params'], {
      'blackPoint': 812.5,
      'whitePoint': 4200.0,
      'd': 2.75,
      'b': 0.0,
      'symmetryPoint': 0.0,
    });
    expect(
      draft.notes.firstWhere((n) => n.opId == 'stretch').outcome,
      'remeasured',
    );
  });

  test(
    'a colour step that skips at level 0 is dropped with its own reason',
    () async {
      darkroom.draftSteps = [
        {
          'opId': 'color_calibrate',
          'opVersion': 1,
          'params': <String, dynamic>{},
          'enabled': true,
        },
        {
          'opId': 'stretch',
          'opVersion': 1,
          'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
          'enabled': true,
        },
      ];
      darkroom.skipReasons = {0: 'no photometric catalogue is installed'};
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId], channels: 3, solved: true);

      final outcome = await buildService(
        catalog: [
          Star(
            id: 'a',
            name: 'a',
            coordinates: const CelestialCoordinate(ra: 83.8 / 15.0, dec: -5.4),
            magnitude: 9.0,
            colorIndex: 0.6,
          ),
        ],
      ).runDawnForSession(sessionId);

      final draft = outcome.report!.masters.single.draft!;
      expect(draft.indexOfOp('color_calibrate'), -1);
      expect(
        draft.notes.firstWhere((n) => n.opId == 'color_calibrate').reason,
        'no photometric catalogue is installed',
      );
      expect(
        darkroom.previewContexts,
        hasLength(1),
        reason:
            'the dropped step was already skipping when the registry measured '
            'the stretch, so the prefix did not move and nothing is re-measured',
      );
    },
  );

  test('an RGB master with no colour-indexed catalogue star drops the colour '
      'step before rendering anything', () async {
    darkroom.draftSteps = [
      {
        'opId': 'color_calibrate',
        'opVersion': 1,
        'params': <String, dynamic>{},
        'enabled': true,
      },
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
    ];
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId], channels: 3);

    final outcome = await buildService().runDawnForSession(sessionId);

    final draft = outcome.report!.masters.single.draft!;
    expect(draft.indexOfOp('color_calibrate'), -1);
    expect(darkroom.previewContexts, isEmpty);
    expect(
      draft.notes.firstWhere((n) => n.opId == 'color_calibrate').reason,
      contains('no solved astrometry'),
    );
  });

  test('a background extraction the registry dropped is retried once at half '
      'the sample spacing', () async {
    darkroom.draftSteps = [
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
    ];
    darkroom.draftNotes = [
      {
        'opId': 'background_extract',
        'outcome': 'omitted',
        'reason': 'too few background samples survived the star mask',
      },
    ];
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);

    final outcome = await buildService().runDawnForSession(sessionId);

    final draft = outcome.report!.masters.single.draft!;
    final index = draft.indexOfOp('background_extract');
    expect(index, 0, reason: 'the retried step takes its canonical place');
    expect(
      (draft.steps[index]['params'] as Map)['sampleSpacing'],
      kBackgroundRetrySampleSpacing,
    );
    expect(
      draft.notes.where((n) => n.opId == 'background_extract').last.outcome,
      'retried',
    );
    // The probe ran at the registry's own measurement dimension.
    expect(
      darkroom.previewContexts.first['maxDimension'],
      kDraftMeasureMaxDimension,
    );
  });

  test('a restored background fit has the stretch measured again over the '
      'stack it ends up on', () async {
    darkroom.draftSteps = [
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
    ];
    darkroom.draftNotes = [
      {
        'opId': 'background_extract',
        'outcome': 'omitted',
        'reason': 'too few background samples survived the star mask',
      },
    ];
    darkroom.screenTransfer = {
      'blackPoint': 96.5,
      'whitePoint': 1850.0,
      'd': 3.5,
      'b': 0.0,
      'symmetryPoint': 0.0,
    };
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);

    final outcome = await buildService().runDawnForSession(sessionId);

    // Two renders: the retry probe, then the measurement over the restored
    // prefix. The second stops one step below the stretch and asks the engine
    // for its own auto transfer over those pixels.
    expect(darkroom.previewContexts, hasLength(2));
    final remeasure = darkroom.previewContexts.last;
    expect(remeasure['encoding'], 'screen');
    expect(remeasure['stopAfter'], 0);
    expect(remeasure['maxDimension'], kDraftMeasureMaxDimension);

    final draft = outcome.report!.masters.single.draft!;
    final stretch = draft.steps[draft.indexOfOp('stretch')];
    expect(stretch['params'], {
      'blackPoint': 96.5,
      'whitePoint': 1850.0,
      'd': 3.5,
      'b': 0.0,
      'symmetryPoint': 0.0,
    });
    final note = draft.notes.firstWhere((n) => n.opId == 'stretch');
    expect(note.outcome, 'remeasured');
    expect(note.reason, contains('denser lattice'));
  });

  test('a stretch re-measurement that fails keeps the measured parameters and '
      'says they are a starting point', () async {
    darkroom.draftSteps = [
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
    ];
    darkroom.draftNotes = [
      {
        'opId': 'background_extract',
        'outcome': 'omitted',
        'reason': 'too few background samples survived the star mask',
      },
    ];
    darkroom.screenPreviewError = const DarkroomSeamException(
      'renderPreview',
      'the master moved under the render',
      'remeasure',
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);

    final outcome = await buildService().runDawnForSession(sessionId);

    expect(
      outcome.succeeded,
      isTrue,
      reason:
          'a measurement that could not be repeated is a note, not a '
          'failed job',
    );
    final draft = outcome.report!.masters.single.draft!;
    expect(draft.indexOfOp('background_extract'), 0);
    expect(draft.steps[draft.indexOfOp('stretch')]['params'], {
      'blackPoint': 0.0,
      'whitePoint': 1.0,
    });
    final note = draft.notes.firstWhere((n) => n.opId == 'stretch');
    expect(note.outcome, 'included');
    expect(note.reason, contains('starting point'));
    expect(note.reason, contains('the master moved under the render'));
  });

  test('a background retry that also fails leaves the step out and records '
      'both attempts', () async {
    darkroom.draftSteps = [
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
    ];
    darkroom.draftNotes = [
      {
        'opId': 'background_extract',
        'outcome': 'omitted',
        'reason': 'too few background samples survived the star mask',
      },
    ];
    darkroom.previewError = const DarkroomSeamException(
      'renderPreview',
      'the background lattice is still too sparse',
      'probe',
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);

    final outcome = await buildService().runDawnForSession(sessionId);

    final draft = outcome.report!.masters.single.draft!;
    expect(draft.indexOfOp('background_extract'), -1);
    final notes = draft.notes
        .where((n) => n.opId == 'background_extract')
        .toList();
    expect(notes, hasLength(2));
    expect(notes.first.reason, contains('star mask'));
    expect(notes.last.reason, contains('still too sparse'));
    expect(
      outcome.succeeded,
      isTrue,
      reason: 'a dropped step is a note, not a failed job',
    );
  });

  test('saturation and curves never enter the draft', () async {
    darkroom.draftSteps = [
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
        'enabled': true,
      },
      {
        'opId': 'saturation',
        'opVersion': 1,
        'params': <String, dynamic>{},
        'enabled': true,
      },
      {
        'opId': 'curves',
        'opVersion': 1,
        'params': <String, dynamic>{},
        'enabled': true,
      },
    ];
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);

    final outcome = await buildService().runDawnForSession(sessionId);

    final draft = outcome.report!.masters.single.draft!;
    expect(draft.steps.map((s) => s['opId']), ['stretch']);
    for (final opId in ['saturation', 'curves']) {
      expect(
        draft.notes.firstWhere((n) => n.opId == opId).reason,
        contains('identity transform'),
      );
    }
  });

  test('cancellation mid-pipeline stops before the next master', () async {
    final sessionId = await insertSession();
    final imageA = await insertSub(sessionId: sessionId);
    final imageB = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageA], filter: 'L');
    await insertMaster(
      imageIds: [imageB],
      filter: 'Ha',
      path: '${workspace.path}/M42_Ha_master.fits',
    );

    final jobId = await DarkroomJobsDao(db).enqueue(sessionId: sessionId);
    final service = buildService();
    darkroom.beforeRegistry = () async {
      if (darkroom.registryCalls.isNotEmpty) return;
      await service.requestCancel(jobId, reason: 'operator stopped the rig');
    };

    final outcome = await service.runJob(jobId);

    expect(outcome.state, DarkroomJobState.cancelled);
    final job = await DarkroomJobsDao(db).getById(jobId);
    expect(job!.state, DarkroomJobState.cancelled);
    expect(job.errorText, contains('Stopped on request'));
    // Exactly one master was drafted before the stop; the second never began.
    expect(darkroom.exportArgs, hasLength(1));
    // The engine's own flag was raised under the job's render id.
    expect(
      darkroom.cancelArgs.single['renderId'],
      DawnAutopilotService.renderIdFor(jobId),
    );
    expect(darkroom.cancelArgs.single['op'], 'cancel');
  });

  test(
    'a cancelled render is decoded by its payload kind, not its prose',
    () async {
      darkroom.previewError = const DarkroomCancelledOutcome(
        id: 'darkroom-job-1',
        phase: 'render',
        payload: {'kind': 'cancelled'},
      );
      darkroom.draftSteps = [
        {
          'opId': 'stretch',
          'opVersion': 1,
          'params': {'blackPoint': 0.0, 'whitePoint': 1.0},
          'enabled': true,
        },
      ];
      darkroom.draftNotes = [
        {
          'opId': 'background_extract',
          'outcome': 'omitted',
          'reason': 'too few background samples survived the star mask',
        },
      ];
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);

      final outcome = await buildService().runDawnForSession(sessionId);

      expect(outcome.state, DarkroomJobState.cancelled);
      final job = await DarkroomJobsDao(db).getById(outcome.jobId);
      expect(job!.errorText, contains('render phase'));
    },
  );

  test(
    'a manual job produces the draft and sends no morning notification',
    () async {
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);

      final outcome = await buildService().processSessionNow(sessionId);

      expect(outcome.succeeded, isTrue);
      final job = await DarkroomJobsDao(db).getById(outcome.jobId);
      expect(job!.kind, DarkroomJobKind.manual);
      expect(notifier.announced, isEmpty);
      expect(outcome.report!.notification!.sent, isFalse);
      expect(outcome.report!.notification!.reason, contains('started by hand'));
      expect(outcome.report!.draftsRendered, 1);
    },
  );

  test('a dawn job records the gate that silenced its notification', () async {
    notifier.decision = const DawnNotificationDecision(
      sent: false,
      reason:
          'The "Sequence Complete" event alert is switched off, so the morning '
          'message was not sent.',
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);

    final outcome = await buildService().runDawnForSession(sessionId);

    expect(notifier.announced, hasLength(1));
    expect(outcome.report!.notification!.sent, isFalse);
    expect(outcome.report!.notification!.reason, contains('switched off'));
    expect(
      outcome.succeeded,
      isTrue,
      reason: 'a silenced notification is not a failed job',
    );
  });

  test(
    'a destination that refuses is a report line, not a failed job',
    () async {
      await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/office"}',
        content: ArtifactContent.values.toSet(),
      );
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);

      final outcome = await buildService().runDawnForSession(sessionId);

      expect(outcome.succeeded, isTrue);
      expect(outcome.report!.delivery, isNotNull);
      expect(outcome.report!.deliveryProblems, isNotEmpty);
      expect(outcome.report!.body, contains('office-pc'));
    },
  );

  test(
    'a stop that lands during delivery ends the job as stopped, not done',
    () async {
      await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/office"}',
        content: ArtifactContent.values.toSet(),
      );
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);

      final jobId = await DarkroomJobsDao(db).enqueue(sessionId: sessionId);
      late final DawnAutopilotService service;
      // The stop arrives after the first file has been handed over, which is
      // the case the operator actually creates by pressing Stop while the
      // copy is running.
      final transport = _StopAfterFirstFileTransport(
        onFirstFile: () => service.requestCancel(jobId),
      );
      service = buildService(transportFactory: (destination, id) => transport);

      final outcome = await service.runJob(jobId);

      expect(outcome.state, DarkroomJobState.cancelled);
      expect(outcome.succeeded, isFalse);
      final job = await DarkroomJobsDao(db).getById(jobId);
      expect(job!.state, DarkroomJobState.cancelled);
      expect(job.errorText, contains('Stopped on request during delivery'));
      expect(job.errorText, contains('still owed'));

      // The report on disk says the same thing the row does.
      expect(outcome.report!.state, DarkroomJobState.cancelled.wire);
      final delivery = outcome.report!.delivery!;
      expect(delivery.delivered, 1);
      expect(delivery.stoppedPending, greaterThan(0));
      expect(delivery.failed, 0);
      expect(delivery.everythingLanded, isFalse);
      expect(delivery.summary, contains('stopped during delivery'));

      // Nothing was announced as a finished night.
      expect(outcome.report!.notification, isNull);
      expect(notifier.announced, isEmpty);

      // And the files the pass never reached are still on the sweep's list.
      final owed = await DeliveryJournalDao(db).listPendingRetry();
      expect(owed, isNotEmpty);
      expect(owed.every((row) => row.attempts == 0), isTrue);
    },
  );

  test('a master with no linear FITS is reported, never dropped', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    final masters = IntegratedMastersDao(db);
    final accumulating = await masters.insertMaster(
      name: 'M42 · L',
      sidecarPath: '${workspace.path}/M42.skmaster',
      status: IntegratedMasterStatus.accumulating,
      accumulationMode: AccumulationMode.runningWeightedMean,
    );
    await masters.recordFoldedFrame(
      masterId: accumulating,
      imageId: imageId,
      accepted: true,
    );

    final outcome = await buildService().runDawnForSession(sessionId);

    // A pass with nothing to draft is not a pass that succeeded. It used to end
    // `done` with an empty error, which the Session Review banner paints
    // nothing for — so the night read "a clean night, no problems detected"
    // with no mention anywhere that the drafting had not happened.
    expect(outcome.succeeded, isFalse);
    expect(outcome.state, DarkroomJobState.failed);
    expect(outcome.failure, contains('still accumulating'));
    expect(outcome.report!.masters, isEmpty);
    expect(outcome.report!.withoutFile, hasLength(1));
    expect(
      outcome.report!.withoutFile.single.reason,
      contains('still accumulating'),
    );
    expect(outcome.report!.body, contains('still accumulating'));
  });

  test(
    'the report states the calibration warnings the integration recorded',
    () async {
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(
        imageIds: [imageId],
        statsJson: jsonEncode({
          'framesIntegrated': 12,
          'framesRejected': 1,
          'calibration': {
            'anchorUnreadable': false,
            'cosmeticCorrection': true,
            'masters': [
              {
                'kind': 'dark',
                'path': '/cal/dark.fits',
                'applied': true,
                'quality': 'fallback',
                'stale': true,
                'mismatches': [
                  {
                    'dimension': 'EXPTIME',
                    'light': '120',
                    'master': '300',
                    'withinTolerance': false,
                  },
                ],
                'unverified': <String>[],
              },
              {
                'kind': 'flat',
                'path': null,
                'applied': false,
                'quality': 'missing',
                'stale': false,
                'mismatches': <dynamic>[],
                'unverified': <String>[],
              },
              {
                'kind': 'bias',
                'path': null,
                'applied': false,
                'quality': 'notRequired',
                'stale': false,
                'mismatches': <dynamic>[],
                'unverified': <String>[],
              },
            ],
          },
          'calibrationWarnings': ['The matched dark was shot 140 days ago.'],
        }),
      );

      final outcome = await buildService().runDawnForSession(sessionId);

      final report = outcome.report!;
      expect(report.calibrationWarned, isTrue);
      expect(report.body, contains('EXPTIME'));
      expect(report.body, contains('No master flat was applied'));
      expect(report.body, contains('140 days ago'));
      expect(
        report.body,
        isNot(contains('bias was applied')),
        reason: 'a not-required bias is not a warning',
      );
    },
  );

  test('a job left running by a dead process is re-queued at open and drained '
      'on the next start', () async {
    final crashDir = await Directory.systemTemp.createTemp('dawn-crash');
    addTearDown(() => crashDir.delete(recursive: true));
    final file = File('${crashDir.path}/skotiq.sqlite');
    final crashedMaster = '${crashDir.path}/M42_master.fits';
    await File(crashedMaster).writeAsString('linear master');

    final first = SkotiqDatabase.forTesting(NativeDatabase(file));
    final sessionId = await first
        .into(first.imagingSessions)
        .insert(ImagingSessionsCompanion.insert(startTime: DateTime.now()));
    final imageId = await first
        .into(first.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: '/l/crash.fits',
            fileName: 'crash.fits',
            frameType: const Value('light'),
            exposureDuration: 120.0,
            capturedAt: DateTime.now(),
            sessionId: Value(sessionId),
            isAccepted: const Value(true),
          ),
        );
    final firstMasters = IntegratedMastersDao(first);
    final masterId = await firstMasters.insertMaster(
      name: 'M42',
      masterFitsPath: crashedMaster,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 100,
      height: 80,
      frameCount: 1,
      totalIntegrationSeconds: 120.0,
    );
    await firstMasters.recordFoldedFrame(
      masterId: masterId,
      imageId: imageId,
      accepted: true,
    );
    final jobId = await DarkroomJobsDao(first).enqueue(sessionId: sessionId);
    // The executor took the job and the process died before it finished.
    await DarkroomJobsDao(first).markRunning(jobId);
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(file));
    addTearDown(second.close);
    final recovered = await DarkroomJobsDao(second).getById(jobId);
    expect(recovered!.state, DarkroomJobState.queued);
    expect(recovered.note, contains('Re-queued'));
    expect(recovered.startedAt, isNull);

    final crashDarkroom = _ScriptedDarkroom(baseMasterRef: crashedMaster);
    final service = DawnAutopilotService(
      jobs: DarkroomJobsDao(second),
      recipes: RecipesDao(second),
      masters: IntegratedMastersDao(second),
      targets: TargetsDao(second),
      resolver: DawnMasterResolver(
        images: ImagesDao(second),
        masters: IntegratedMastersDao(second),
      ),
      drafts: DawnDraftBuilder(darkroom: crashDarkroom),
      darkroom: crashDarkroom,
      photometry: DawnPhotometryResolver(
        coneSearch: (centre, radius, {maxMagnitude}) async => const [],
      ),
      delivery: DeliveryService(
        targets: DeliveryTargetsDao(second),
        journal: DeliveryJournalDao(second),
        transportFactory: (destination, jobId) => _RefusingTransport(),
      ),
      notifier: notifier,
      outputDirectory: () async => crashDir.path,
    );

    final outcomes = await service.drainQueue();

    expect(outcomes, hasLength(1));
    expect(outcomes.single.jobId, jobId);
    expect(outcomes.single.succeeded, isTrue);
    final finished = await DarkroomJobsDao(second).getById(jobId);
    expect(finished!.state, DarkroomJobState.done);
    expect(finished.attempts, 2, reason: 'the restart is a second start');
    expect(await RecipesDao(second).listForMaster(crashedMaster), hasLength(1));
  });

  test(
    'a job failed at the attempts cap drops the note the dead attempt left',
    () async {
      final capDir = await Directory.systemTemp.createTemp('dawn-cap');
      addTearDown(() => capDir.delete(recursive: true));
      final file = File('${capDir.path}/skotiq.sqlite');

      final first = SkotiqDatabase.forTesting(NativeDatabase(file));
      final sessionId = await first
          .into(first.imagingSessions)
          .insert(ImagingSessionsCompanion.insert(startTime: DateTime.now()));
      final jobId = await DarkroomJobsDao(first).enqueue(sessionId: sessionId);
      await DarkroomJobsDao(first).markRunning(jobId);
      // The state a job reaches after it has killed the process on every allowed
      // start: still `running`, its attempts spent, carrying the note the last
      // recovery wrote.
      await first.customStatement(
        'UPDATE darkroom_jobs SET attempts = ?, note = ? WHERE id = ?',
        [
          kDarkroomJobMaxAttempts,
          'Re-queued: the previous process exited while this job was running.',
          jobId,
        ],
      );
      await first.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(file));
      addTearDown(second.close);
      final recovered = await DarkroomJobsDao(second).getById(jobId);

      expect(recovered!.state, DarkroomJobState.failed);
      expect(recovered.errorText, contains('not retried'));
      expect(
        recovered.note,
        isNot(contains('Re-queued')),
        reason: 'a failed row must not say it is going to run again',
      );
      expect(recovered.note, contains('not re-queued'));
    },
  );

  test(
    'a job that names no session fails instead of drafting nothing quietly',
    () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      final outcome = await buildService().runJob(jobId);

      expect(outcome.state, DarkroomJobState.failed);
      expect(outcome.failure, contains('names no imaging session'));
    },
  );

  test('a master whose pixels could not be read is held back from delivery '
      'while the rest of the night goes', () async {
    final delivered = <String>[];
    await DeliveryTargetsDao(db).create(
      name: 'office-pc',
      kind: ArtifactDestinationKind.watchedFolder,
      configJson: '{"path":"/mnt/office"}',
      content: ArtifactContent.values.toSet(),
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    final goodPath = '${workspace.path}/M42_L_master.fits';
    final badPath = '${workspace.path}/M42_R_master.fits';
    await insertMaster(imageIds: [imageId], filter: 'L', path: goodPath);
    await insertMaster(imageIds: [imageId], filter: 'R', path: badPath);
    // The registry refuses that master's pixels, the way it refuses a
    // truncated FITS: the draft can never be composed for it.
    darkroom.registryErrors = {
      badPath: DarkroomSeamException(
        'registry',
        "cannot read '$badPath' as FITS: IO error",
        const FormatException('unexpected end of FITS data'),
      ),
    };

    final outcome = await buildService(
      transportFactory: (destination, jobId) => _RecordingTransport(delivered),
    ).runDawnForSession(sessionId);

    expect(outcome.succeeded, isTrue);
    final unreadable = outcome.report!.masters.firstWhere(
      (m) => m.master.masterFitsPath == badPath,
    );
    expect(unreadable.pixelsWereRead, isFalse);
    expect(unreadable.failure, contains('cannot read'));

    expect(
      delivered,
      isNot(contains(badPath)),
      reason: 'a master the pass just called unreadable is not the night',
    );
    expect(delivered, contains(goodPath));
    expect(delivered.where((f) => f.endsWith('_report.json')), hasLength(1));
    expect(
      outcome.report!.deliveryProblems.join('\n'),
      contains('was not delivered'),
    );
    expect(outcome.report!.body, contains('was not delivered'));
    final job = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(job!.note, contains('not delivered'));
    // Nothing in the journal claims the unreadable file reached anywhere.
    final journal = await DeliveryJournalDao(db).listForJob(outcome.jobId);
    expect(journal.map((row) => row.filePath), isNot(contains(badPath)));
  });

  test('a master that vanishes after it is drafted costs only itself, never '
      'the drafts and the report', () async {
    final delivered = <String>[];
    await DeliveryTargetsDao(db).create(
      name: 'office-pc',
      kind: ArtifactDestinationKind.watchedFolder,
      configJson: '{"path":"/mnt/office"}',
      content: ArtifactContent.values.toSet(),
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    final keptPath = '${workspace.path}/M42_L_master.fits';
    final goingPath = '${workspace.path}/M42_R_master.fits';
    await insertMaster(imageIds: [imageId], filter: 'L', path: keptPath);
    await insertMaster(imageIds: [imageId], filter: 'R', path: goingPath);
    // Both masters draft; that file then disappears between its draft and
    // delivery, which is what a cleanup script or a pulled drive does.
    darkroom.afterExport = (args) async {
      if (args['masterPath'] == goingPath) File(goingPath).deleteSync();
    };

    final outcome = await buildService(
      transportFactory: (destination, jobId) => _RecordingTransport(delivered),
    ).runDawnForSession(sessionId);

    expect(outcome.succeeded, isTrue);
    expect(delivered, isNot(contains(goingPath)));
    expect(delivered, contains(keptPath));
    expect(
      delivered.where((f) => f.endsWith('_report.json')),
      hasLength(1),
      reason: 'the night report always goes',
    );
    expect(
      delivered.where((f) => f.endsWith('.jpg')),
      hasLength(2),
      reason: 'both drafts were rendered before the file went missing',
    );
    expect(outcome.report!.delivery, isNotNull);
    expect(
      outcome.report!.deliveryProblems.join('\n'),
      contains('no longer on disk'),
    );
  });

  test('a master TRUNCATED after it is drafted is withheld from delivery and '
      'the report says so', () async {
    final delivered = <String>[];
    await DeliveryTargetsDao(db).create(
      name: 'office-pc',
      kind: ArtifactDestinationKind.watchedFolder,
      configJson: '{"path":"/mnt/office"}',
      content: ArtifactContent.values.toSet(),
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    final keptPath = '${workspace.path}/M42_L_master.fits';
    final shortPath = '${workspace.path}/M42_R_master.fits';
    await insertMaster(imageIds: [imageId], filter: 'L', path: keptPath);
    await insertMaster(imageIds: [imageId], filter: 'R', path: shortPath);
    // The file is still THERE — a stat finds it, a checksum computes over it,
    // and every stage before this one has already passed. It is simply half
    // the file the pass read, which is what a disk that filled up mid-write or
    // an interrupted sync leaves behind.
    darkroom.afterExport = (args) async {
      if (args['masterPath'] != shortPath) return;
      final file = File(shortPath);
      final whole = await file.readAsBytes();
      await file.writeAsBytes(whole.sublist(0, whole.length ~/ 2));
    };

    final outcome = await buildService(
      transportFactory: (destination, jobId) => _RecordingTransport(delivered),
    ).runDawnForSession(sessionId);

    expect(outcome.succeeded, isTrue);
    final short = outcome.report!.masters.firstWhere(
      (m) => m.master.masterFitsPath == shortPath,
    );
    // The draft stage is untouched: these pixels WERE read, and the draft it
    // composed from them is real. Only delivery refuses.
    expect(short.pixelsWereRead, isTrue);
    expect(short.hasDraft, isTrue);
    expect(short.deliverable, isFalse);
    expect(short.withheldFromDelivery, contains('changed after the pass read'));

    expect(
      delivered,
      isNot(contains(shortPath)),
      reason: 'bytes nothing in this pass measured are not the night',
    );
    expect(delivered, contains(keptPath));
    expect(
      delivered.where((f) => f.endsWith('.jpg')),
      hasLength(2),
      reason: 'both drafts were rendered before the file was cut short',
    );
    expect(
      outcome.report!.deliveryProblems.join('\n'),
      contains('changed after the pass read it'),
    );
    expect(outcome.report!.body, contains('was not delivered'));
    final job = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(job!.note, contains('1 master was not delivered'));
    final journal = await DeliveryJournalDao(db).listForJob(outcome.jobId);
    expect(journal.map((row) => row.filePath), isNot(contains(shortPath)));
    // The delivery run's own counts agree: nothing claims 4 delivered.
    expect(outcome.report!.delivery!.problems, isEmpty);
    expect(delivered.where((f) => f.endsWith('.fits')), hasLength(1));
  });

  test(
    'a master nothing touched between the draft and delivery still goes',
    () async {
      final delivered = <String>[];
      await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/office"}',
        content: ArtifactContent.values.toSet(),
      );
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      final path = '${workspace.path}/M42_L_master.fits';
      await insertMaster(imageIds: [imageId], filter: 'L', path: path);

      final outcome = await buildService(
        transportFactory: (destination, jobId) =>
            _RecordingTransport(delivered),
      ).runDawnForSession(sessionId);

      expect(outcome.succeeded, isTrue);
      final master = outcome.report!.masters.single;
      expect(master.deliverable, isTrue);
      expect(master.withheldFromDelivery, isNull);
      expect(master.sourceAtRead, isNotNull);
      expect(delivered, contains(path));
      expect(outcome.report!.deliveryProblems, isEmpty);
      final job = await DarkroomJobsDao(db).getById(outcome.jobId);
      expect(job!.note, isNot(contains('not delivered')));
    },
  );

  // D3G1-01. Reproduced on the release bundle: one master overwritten mid-pass
  // with another master's FITS of exactly the same size, its mtime restored
  // with `touch -r`, was delivered under the original's name with
  // deliveryProblems [] and withheldFromDelivery null — the drop then held G's
  // pixels in B's file while the draft beside it had been rendered from B's.
  // Size and mtime are what a restoring writer puts back; only the bytes
  // answer.
  test(
    'a master SUBSTITUTED after it is drafted — same size, same mtime, '
    'different bytes — is withheld and the report names the contents',
    () async {
      final delivered = <String>[];
      await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/office"}',
        content: ArtifactContent.values.toSet(),
      );
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      final keptPath = '${workspace.path}/M42_L_master.fits';
      final swappedPath = '${workspace.path}/M42_R_master.fits';
      await insertMaster(imageIds: [imageId], filter: 'L', path: keptPath);
      await insertMaster(imageIds: [imageId], filter: 'R', path: swappedPath);
      // Every metadata field the old guard read is put back exactly as it was:
      // the replacement is written to the same length and the original
      // modification time is restored, which is what `rsync --times`, `cp -p`
      // and a restic restore all do.
      final swapped = File(swappedPath);
      final original = await swapped.readAsBytes();
      final stolen = Uint8List.fromList(
        List<int>.generate(original.length, (i) => (original[i] + 7) & 0xff),
      );
      // Stamped before the pass opens it and stamped again after the swap, so
      // both readings see the same modification time no matter what resolution
      // the filesystem stores. That is what a restoring writer achieves.
      final stamp = DateTime.fromMillisecondsSinceEpoch(
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000,
      );
      await swapped.setLastModified(stamp);
      darkroom.afterExport = (args) async {
        if (args['masterPath'] != swappedPath) return;
        await swapped.writeAsBytes(stolen);
        await swapped.setLastModified(stamp);
      };

      final outcome = await buildService(
        transportFactory: (destination, jobId) =>
            _RecordingTransport(delivered),
      ).runDawnForSession(sessionId);

      expect(outcome.succeeded, isTrue);
      // The metadata the old guard compared is genuinely unchanged, so this test
      // only passes on a guard that reads the bytes.
      final now = await swapped.stat();
      expect(now.size, original.length);
      final substituted = outcome.report!.masters.firstWhere(
        (m) => m.master.masterFitsPath == swappedPath,
      );
      expect(substituted.sourceAtRead!.bytes, now.size);
      expect(
        substituted.sourceAtRead!.modified.isAtSameMomentAs(now.modified),
        isTrue,
        reason: 'the substitution restored the modification time',
      );

      // The draft stage is untouched: these pixels WERE read, and the draft it
      // composed from them is real. Only delivery refuses.
      expect(substituted.pixelsWereRead, isTrue);
      expect(substituted.hasDraft, isTrue);
      expect(substituted.deliverable, isFalse);
      expect(
        substituted.withheldFromDelivery,
        contains('changed after the pass read it'),
      );
      expect(
        substituted.withheldFromDelivery,
        contains('its contents now hash to'),
        reason: 'the sentence names what differs — the contents, not the size',
      );
      expect(
        substituted.withheldFromDelivery,
        contains(substituted.sourceAtRead!.digest),
      );

      expect(
        delivered,
        isNot(contains(swappedPath)),
        reason: 'bytes nothing in this pass measured are not the night',
      );
      expect(delivered, contains(keptPath));
      expect(
        outcome.report!.deliveryProblems.join('\n'),
        contains('changed after the pass read it'),
      );
      final journal = await DeliveryJournalDao(db).listForJob(outcome.jobId);
      expect(journal.map((row) => row.filePath), isNot(contains(swappedPath)));
    },
  );

  test('the pass records the SHA-256 of every master it drafts from, and the '
      'report carries it', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    final path = '${workspace.path}/M42_L_master.fits';
    await insertMaster(imageIds: [imageId], filter: 'L', path: path);

    final outcome = await buildService().runDawnForSession(sessionId);

    final master = outcome.report!.masters.single;
    final onDisk = await sha256OfFile(File(path));
    expect(master.sourceAtRead!.digest, onDisk);
    final json =
        jsonDecode(File(outcome.reportPath!).readAsStringSync())
            as Map<String, dynamic>;
    final reported =
        ((json['masters'] as List).single
                as Map<String, dynamic>)['sourceAtRead']
            as Map<String, dynamic>;
    expect(reported['sha256'], onDisk);
  });

  // D3LC2-F1. Reproduced on the release bundle GUI: navigating away and back
  // built a fresh Session Review state whose `_darkroomRunning` latch was
  // false, so "Process now" was offered over a session already being
  // processed. Two `manual` rows then ran concurrently (59 samples at 200 ms
  // with two `running` rows) and Stop cancelled only the newer one while the
  // older ran on to done, delivery included. The guard is the durable row.
  test('a second pass over a session already being processed is refused, and '
      'the refusal names the live job', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    final service = buildService();

    // Hold the first pass inside the render so the second press lands while it
    // is genuinely running, which is the shape the GUI reproduced.
    final firstIsRendering = Completer<void>();
    final releaseFirst = Completer<void>();
    darkroom.beforeRegistry = () async {
      if (!firstIsRendering.isCompleted) firstIsRendering.complete();
      await releaseFirst.future;
    };

    final first = service.processSessionNow(sessionId);
    await firstIsRendering.future;

    await expectLater(
      service.processSessionNow(sessionId),
      throwsA(
        isA<DarkroomSessionBusyException>()
            .having((e) => e.sessionId, 'sessionId', sessionId)
            .having((e) => e.state, 'state', DarkroomJobState.running)
            .having((e) => e.message, 'message', contains('already running')),
      ),
    );
    // No second row was written: the refusal is before the enqueue.
    expect(await DarkroomJobsDao(db).listForSession(sessionId), hasLength(1));

    releaseFirst.complete();
    darkroom.beforeRegistry = null;
    final outcome = await first;
    expect(outcome.succeeded, isTrue);

    // Once it has ended the session is free again.
    final second = await service.processSessionNow(sessionId);
    expect(second.succeeded, isTrue);
    expect(await DarkroomJobsDao(db).listForSession(sessionId), hasLength(2));
  });

  test('two presses that arrive together still produce one pass', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    final service = buildService();

    // No await between them: the check and the insert are two awaits apart, so
    // an unserialized guard lets both read an empty queue and enqueue.
    final results = await Future.wait<Object>([
      service.processSessionNow(sessionId).then<Object>((o) => o),
      service
          .processSessionNow(sessionId)
          .then<Object>((o) => o, onError: (Object error) => error),
    ]);

    expect(
      results.whereType<DarkroomSessionBusyException>(),
      hasLength(1),
      reason: 'exactly one of the two presses is refused',
    );
    expect(results.whereType<DawnJobOutcome>(), hasLength(1));
    expect(await DarkroomJobsDao(db).listForSession(sessionId), hasLength(1));
  });

  test(
    'a pass still queued for a session refuses the next request too',
    () async {
      final sessionId = await insertSession();
      final jobs = DarkroomJobsDao(db);
      await jobs.enqueue(
        sessionId: sessionId,
        kind: DarkroomJobKind.dawn,
        note: 'left queued by the crash recovery',
      );

      await expectLater(
        buildService().processSessionNow(sessionId),
        throwsA(
          isA<DarkroomSessionBusyException>()
              .having((e) => e.state, 'state', DarkroomJobState.queued)
              .having((e) => e.message, 'message', contains('already queued')),
        ),
      );
      expect(await jobs.listForSession(sessionId), hasLength(1));
    },
  );

  test('a pass over ANOTHER session is not refused', () async {
    final busySession = await insertSession();
    final freeSession = await insertSession();
    final imageId = await insertSub(sessionId: freeSession);
    await insertMaster(imageIds: [imageId]);
    await DarkroomJobsDao(db).enqueue(
      sessionId: busySession,
      kind: DarkroomJobKind.manual,
      note: 'holding a different night',
    );

    final outcome = await buildService().processSessionNow(freeSession);

    expect(outcome.succeeded, isTrue);
  });

  test('every live pass over a session is reported, oldest first', () async {
    final sessionId = await insertSession();
    final jobs = DarkroomJobsDao(db);
    // The shape a build without the enqueue guard already left on disk: two
    // live rows over one night. A Stop has to reach both.
    final older = await jobs.enqueue(
      sessionId: sessionId,
      kind: DarkroomJobKind.manual,
      createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
    );
    final newer = await jobs.enqueue(
      sessionId: sessionId,
      kind: DarkroomJobKind.manual,
      createdAt: DateTime.now(),
    );
    final done = await jobs.enqueue(
      sessionId: sessionId,
      kind: DarkroomJobKind.manual,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    await jobs.markRunning(done);
    await jobs.markDone(done);

    final live = await buildService().liveJobsForSession(sessionId);

    expect(live.map((j) => j.id), [older, newer]);
  });

  test('a night that rendered no draft never announces "0 drafts"', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    darkroom.beforeRegistry = () async {
      throw const DarkroomSeamException(
        'registry',
        'cannot read as FITS',
        'unexpected end of FITS data',
      );
    };

    final outcome = await buildService().runDawnForSession(sessionId);

    final report = outcome.report!;
    expect(report.draftsRendered, 0);
    expect(report.headline, isNot(contains('0 drafts')));
    expect(report.headline, contains('no draft was rendered'));
    expect(
      (jsonDecode(File(outcome.reportPath!).readAsStringSync())
          as Map<String, dynamic>)['headline'],
      report.headline,
    );
  });

  test('a night that rendered no draft ends failed, naming the master that '
      'stopped it, and the report on disk says the same', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    darkroom.beforeRegistry = () async {
      throw const DarkroomSeamException(
        'registry',
        'cannot read as FITS',
        'unexpected end of FITS data',
      );
    };

    final outcome = await buildService().runDawnForSession(sessionId);

    // `done` with a NULL error_text is what the Session Review banner
    // deliberately paints nothing for, so a pass that produced no draft was
    // invisible on the one screen the operator opens the next morning.
    expect(outcome.state, DarkroomJobState.failed);
    expect(outcome.succeeded, isFalse);
    expect(outcome.failure, contains('cannot read as FITS'));

    final job = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(job!.state, DarkroomJobState.failed);
    expect(job.errorText, isNotNull);
    expect(job.errorText, contains('rendered no draft'));
    // The note is the banner's second sentence; without this it still named
    // the last stage that ran ("Sending the morning report").
    expect(job.note, contains('the night report carries'));
    // And it is a FINISHED sentence: the banner frames a note that does not
    // punctuate itself as the stage the pass stopped at — "It was No draft
    // was rendered … when it stopped" — which is a stop this pass, having
    // run every stage, never made.
    expect(job.note, endsWith('.'));

    final onDisk =
        jsonDecode(File(outcome.reportPath!).readAsStringSync())
            as Map<String, dynamic>;
    expect(onDisk['state'], DarkroomJobState.failed.wire);
    expect(onDisk['failure'], job.errorText);
    // The morning message still goes out: the pass that produced nothing is
    // the one the operator most needs told about.
    expect((onDisk['notification'] as Map<String, dynamic>)['sent'], isNotNull);
  });

  test(
    'a session with no integrated master at all ends failed and says what to '
    'do about it',
    () async {
      final sessionId = await insertSession();

      final outcome = await buildService().runDawnForSession(sessionId);

      expect(outcome.state, DarkroomJobState.failed);
      expect(outcome.failure, contains('no integrated master'));
      expect(outcome.failure, contains('Session Review'));
    },
  );

  test('a draft is named for the target and the filter it covers', () async {
    final sessionId = await insertSession();
    final targetId = await insertTarget('NGC 7000');
    final imageId = await insertSub(sessionId: sessionId, targetId: targetId);
    await insertMaster(imageIds: [imageId], targetId: targetId, filter: 'Ha');

    await buildService().runDawnForSession(sessionId);

    final recipe = (await RecipesDao(db).listForMaster(masterPath)).single;
    expect(recipe.name, 'NGC 7000 Ha draft');
  });

  test('a re-run over the same master supersedes its own draft instead of '
      'stacking a second one', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    final recipes = RecipesDao(db);

    await buildService().runDawnForSession(sessionId);
    final first = (await recipes.listForMaster(masterPath)).single;

    // The second pass measures a different stack, the way a resumed attempt
    // re-derives the draft from the same master.
    darkroom.draftSteps = [
      {
        'opId': 'crop',
        'opVersion': 1,
        'params': <String, dynamic>{},
        'enabled': true,
      },
      {
        'opId': 'stretch',
        'opVersion': 1,
        'params': {'blackPoint': 0.25, 'whitePoint': 0.9},
        'enabled': true,
      },
    ];
    final second = await buildService().runDawnForSession(sessionId);

    final rows = await recipes.listForMaster(masterPath);
    expect(rows, hasLength(1), reason: 'one master, one autopilot draft');
    expect(rows.single.id, first.id, reason: 'the same row, rewritten');
    expect(second.report!.masters.single.recipeId, first.id);
    expect(
      (jsonDecode(rows.single.stepsJson) as List).map(
        (s) => (s as Map)['opId'],
      ),
      ['crop', 'stretch'],
      reason: 'the row carries the second pass\'s measurements',
    );
  });

  test('a draft the operator has branched from is left alone and the next '
      'pass writes its own row', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    final recipes = RecipesDao(db);

    await buildService().runDawnForSession(sessionId);
    final first = (await recipes.listForMaster(masterPath)).single;
    await recipes.branchFrom(
      parentRecipeId: first.id!,
      divergenceIndex: 1,
      name: 'my version',
    );

    await buildService().runDawnForSession(sessionId);

    final roots = (await recipes.listForMaster(
      masterPath,
    )).where((r) => r.parentRecipeId == null).toList();
    expect(roots, hasLength(2));
    expect(
      (jsonDecode(roots.firstWhere((r) => r.id == first.id).stepsJson) as List)
          .length,
      3,
      reason: 'the branched row keeps the steps its branch diverged from',
    );
  });

  test('a stopped job names the stage in the row and keeps the raw exception '
      'in the log', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    darkroom.beforeRegistry = () async {
      throw StateError(
        'SqliteException(5): while executing statement, database is locked\n'
        '  Causing statement: UPDATE darkroom_jobs SET state = ?, '
        'parameters: failed, 1786932105',
      );
    };

    final outcome = await buildService().runDawnForSession(sessionId);

    expect(outcome.state, DarkroomJobState.failed);
    final job = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(job!.errorText, startsWith('The dawn pass stopped while '));
    expect(job.errorText, contains('drafting'));
    expect(
      job.errorText,
      isNot(contains('Causing statement')),
      reason: 'the SQL and its bound parameters belong in the log',
    );
    expect(job.errorText, isNot(contains('parameters:')));
  });

  test(
    'an over-long error keeps its head and its tail, not just its head',
    () async {
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);
      darkroom.beforeRegistry = () async {
        throw StateError(
          "PathAccessException: Creation failed, path = '${'/very-long-dir' * 20}"
          "/darkroom' (OS Error: Permission denied, errno = 13)",
        );
      };

      final outcome = await buildService().runDawnForSession(sessionId);

      final job = await DarkroomJobsDao(db).getById(outcome.jobId);
      expect(job!.errorText, contains('PathAccessException'));
      expect(job.errorText, contains('…'));
      expect(
        job.errorText,
        contains('Permission denied, errno = 13'),
        reason: 'the half that says what to do about it survives the elision',
      );
    },
  );

  test('a refused failure write is retried rather than left running with no '
      'error at all', () async {
    final jobs = _FlakyJobsDao(db)..refuseFailedWrites = 2;
    final jobId = await jobs.enqueue();

    final outcome = await buildService(jobs: jobs).runJob(jobId);

    expect(jobs.failedWriteAttempts, 3);
    expect(outcome.state, DarkroomJobState.failed);
    final job = await DarkroomJobsDao(db).getById(jobId);
    expect(job!.state, DarkroomJobState.failed);
    expect(job.errorText, contains('names no imaging session'));
  });

  test('one job that cannot be recorded does not abort the drain', () async {
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    final jobs = _FlakyJobsDao(db);
    final wedged = await jobs.enqueue(
      sessionId: sessionId,
      kind: DarkroomJobKind.dawn,
    );
    final follower = await jobs.enqueue(
      sessionId: sessionId,
      kind: DarkroomJobKind.dawn,
    );
    jobs.refuseToStart.add(wedged);

    final outcomes = await buildService(jobs: jobs).drainQueue();

    expect(outcomes.map((o) => o.jobId), [follower]);
    final second = await DarkroomJobsDao(db).getById(follower);
    expect(second!.state, DarkroomJobState.done);
    final first = await DarkroomJobsDao(db).getById(wedged);
    expect(
      first!.state,
      DarkroomJobState.queued,
      reason: 'the row it could not start is left for the next open',
    );
  });

  test(
    'a report is never written claiming an ending the row never took',
    () async {
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);
      final jobs = _FlakyJobsDao(db)..refuseDoneWrites = 99;

      final outcome = await buildService(
        jobs: jobs,
      ).runDawnForSession(sessionId);

      expect(outcome.state, DarkroomJobState.failed);
      final onDisk =
          jsonDecode(
                File(
                  '${output.path}/darkroom/job_${outcome.jobId}_report.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(onDisk['state'], 'failed');
      expect(onDisk['failure'], contains('closing the job row'));
    },
  );

  test(
    'the copy of the report that leaves the rig says what it cannot yet know, '
    'instead of reading as a job that stopped without finishing',
    () async {
      // The real watched-folder transport over a real drop directory, so the
      // file this reads is the one an operator would find at the destination —
      // the same comparison the D1 sim-night harness makes.
      final drop = Directory('${workspace.path}/drop')
        ..createSync(recursive: true);
      await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: jsonEncode({'path': drop.path, 'rigId': 'shed'}),
        content: ArtifactContent.values.toSet(),
      );
      final sessionId = await insertSession();
      final imageId = await insertSub(sessionId: sessionId);
      await insertMaster(imageIds: [imageId]);

      final outcome = await buildService(
        transportFactory: (destination, jobId) => WatchedFolderTransport(
          destination: destination,
          jobId: jobId,
          freeSpace: const _AmpleSpace(),
        ),
      ).runDawnForSession(sessionId);

      expect(outcome.state, DarkroomJobState.done);
      // The delivered copy is named for the PASS that wrote it, and the rig
      // keeps its own copy under the job's name; they are two files.
      final shippedFile = File(
        '${drop.path}/shed-job_${outcome.jobId}_pass1_report.json',
      );
      final shipped =
          jsonDecode(shippedFile.readAsStringSync()) as Map<String, dynamic>;

      // The lifecycle word is the one that describes the instant it was
      // written. `running` beside a finishedAt read as a job that had stopped
      // without finishing.
      expect(shipped['state'], 'delivering');
      expect(shipped['state'], isNot('running'));
      expect(shipped['finishedAt'], isNotNull);

      // The two blocks it cannot hold are named, with where they live.
      final pending = shipped['pending'] as Map<String, dynamic>;
      expect(pending['blocks'], ['delivery', 'notification']);
      expect(pending['note'], contains('delivery was in progress'));
      expect(pending['note'], contains('the copy on the rig carries both'));
      expect(shipped['body'], contains('delivery was in progress'));

      // Every pass fact it DOES know still states itself as done, and every
      // key keeps the type a consumer already reads it at.
      expect(shipped['draftsRendered'], 1);
      expect(shipped['headline'], contains('draft is ready'));
      expect(shipped['delivery'], isNull);
      expect(shipped['notification'], isNull);

      // The rig's copy is the completed one, and it claims nothing pending.
      final onRig =
          jsonDecode(
                File(
                  '${output.path}/darkroom/job_${outcome.jobId}_report.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(onRig['state'], 'done');
      expect(onRig['pending'], isNull);
      expect(
        (onRig['delivery'] as Map<String, dynamic>)['delivered'],
        drop.listSync().length,
        reason: 'the count it reports is the set that reached the drop',
      );
      expect((onRig['notification'] as Map<String, dynamic>)['sent'], isTrue);

      // The copy delivery took is never rewritten: its source on the rig still
      // holds the exact bytes that landed, which is what lets the retry sweep
      // re-read it and what makes a second delivery of it verify as
      // already-there rather than as a conflict.
      expect(
        File(
          '${output.path}/darkroom/job_${outcome.jobId}_pass1_report.json',
        ).readAsBytesSync(),
        shippedFile.readAsBytesSync(),
      );
    },
  );

  test('a pass re-run after a crash delivers its own night report instead of '
      'colliding with the previous pass at one shared name', () async {
    // Real transport over a real drop directory: the refusal being tested —
    // `destinationConflict` on a name the destination already holds with
    // different bytes — is the transport's, not a fake's.
    final drop = Directory('${workspace.path}/drop')
      ..createSync(recursive: true);
    await DeliveryTargetsDao(db).create(
      name: 'office-pc',
      kind: ArtifactDestinationKind.watchedFolder,
      configJson: jsonEncode({'path': drop.path, 'rigId': 'shed'}),
      content: ArtifactContent.values.toSet(),
    );
    final sessionId = await insertSession();
    final imageId = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [imageId]);
    DawnAutopilotService withRealTransport() => buildService(
      transportFactory: (destination, jobId) => WatchedFolderTransport(
        destination: destination,
        jobId: jobId,
        freeSpace: const _AmpleSpace(),
      ),
    );

    final first = await withRealTransport().runDawnForSession(sessionId);
    expect(first.state, DarkroomJobState.done);

    // What a rig losing power leaves behind, and what the open-time
    // recovery (`_recoverInterruptedDarkroomJobs`) does with it: the row is
    // put back to `queued` for the next start's drainQueue to pick up.
    await db.customUpdate(
      'UPDATE darkroom_jobs SET state = ?, started_at = NULL, '
      'finished_at = NULL WHERE id = ?',
      variables: [
        Variable<String>(DarkroomJobState.queued.wire),
        Variable<int>(first.jobId),
      ],
      updateKind: UpdateKind.update,
    );

    final resumed = await withRealTransport().drainQueue();
    expect(resumed.map((o) => o.jobId), [first.jobId]);
    expect(resumed.single.state, DarkroomJobState.done);

    // The whole point: the re-run's report LANDED. Under one name per job
    // this row went `failed` with `destinationConflict` — terminal, so no
    // sweep and no retry could ever clear it, and the morning report said a
    // file had not arrived that never could.
    final journal = await DeliveryJournalDao(db).listForJob(first.jobId);
    final reports = journal
        .where((row) => row.filePath.endsWith('_report.json'))
        .toList();
    expect(reports, hasLength(2));
    expect(
      reports.map((row) => row.state),
      everyElement(DeliveryAttemptState.delivered),
    );
    expect(
      reports.map((row) => row.filePath),
      containsAll([
        '${output.path}/darkroom/job_${first.jobId}_pass1_report.json',
        '${output.path}/darkroom/job_${first.jobId}_pass2_report.json',
      ]),
    );

    // Both passes' copies are at the destination, each once, and the second
    // pass's is the one the resumed run wrote.
    expect(
      File(
        '${drop.path}/shed-job_${first.jobId}_pass1_report.json',
      ).existsSync(),
      isTrue,
    );
    final secondShipped =
        jsonDecode(
              File(
                '${drop.path}/shed-job_${first.jobId}_pass2_report.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(secondShipped['jobId'], first.jobId);
    expect(secondShipped['state'], 'delivering');

    // The rig's own copy keeps the job's name and is the CURRENT account of
    // it — the resumed pass's, complete with its delivery outcome.
    expect(
      resumed.single.reportPath,
      '${output.path}/darkroom/job_${first.jobId}_report.json',
    );
    final onRig =
        jsonDecode(File(resumed.single.reportPath!).readAsStringSync())
            as Map<String, dynamic>;
    expect(onRig['state'], 'done');
    expect(onRig['deliveryProblems'], isEmpty);
    expect(
      (onRig['delivery'] as Map<String, dynamic>)['failed'],
      0,
      reason: 'nothing about the resumed pass was refused',
    );
  });

  // The one-pass-at-a-time rule used to belong to `drainQueue`'s loop, so it
  // held only for the rows that loop owned: `runDawnForSession` and
  // `processSessionNow` enqueued and then ran their job straight away, and the
  // per-session guard stopped only a second pass over the SAME night. A dawn
  // pass over last night and a "Process now" over a different night therefore
  // ran side by side — measured on the release bundle, two rows held `running`
  // for minutes — fighting over the one process-wide render cache the rule
  // exists to protect.
  test(
    'a dawn pass and a Process now over different nights run one at a time',
    () async {
      final lastNight = await insertSession();
      final imageA = await insertSub(sessionId: lastNight);
      await insertMaster(imageIds: [imageA], filter: 'L');

      final otherNight = await insertSession();
      final imageB = await insertSub(sessionId: otherNight);
      await insertMaster(
        imageIds: [imageB],
        filter: 'Ha',
        path: '${workspace.path}/M42_Ha_master.fits',
      );

      final service = buildService();
      // Park the first pass inside its pipeline, where a real render spends its
      // minutes, and hold it there while the second pass is asked for.
      final parked = Completer<void>();
      final release = Completer<void>();
      darkroom.beforeRegistry = () async {
        if (parked.isCompleted) return;
        parked.complete();
        await release.future;
      };

      final dawn = service.runDawnForSession(lastNight);
      await parked.future;
      final manual = service.processSessionNow(otherNight);

      // Let the second submission get as far as it can — its row is enqueued
      // and its position noted, then it waits. Sampled while the first pass is
      // frozen, the way the finding was measured on the release bundle: how
      // many rows hold `running` at once, and how far the second one got.
      DarkroomJob? second;
      var mostRunningAtOnce = 0;
      for (var i = 0; i < 400; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final live = await db
            .customSelect(
              "SELECT count(*) AS n FROM darkroom_jobs WHERE state = 'running'",
            )
            .getSingle();
        final n = live.read<int>('n');
        if (n > mostRunningAtOnce) mostRunningAtOnce = n;
        final rows = await DarkroomJobsDao(db).listForSession(otherNight);
        if (rows.isNotEmpty) {
          second = rows.last;
          if (second.note != null && second.note!.contains('Waiting')) break;
        }
      }
      expect(second, isNotNull, reason: 'the manual pass recorded no row');

      expect(
        mostRunningAtOnce,
        1,
        reason: 'two Darkroom passes held `running` at the same time',
      );
      expect(
        second!.state,
        DarkroomJobState.queued,
        reason: 'the second pass ran while the first was frozen mid-render',
      );
      // Session Review's queued banner reads this note back verbatim, so a
      // pass that will not start until the one ahead finishes says so rather
      // than showing the label its enqueue wrote.
      expect(second.note, contains('Waiting for the Darkroom pass ahead'));

      release.complete();
      final first = await dawn;
      final follower = await manual;

      // Both complete: waiting its turn is a delay, not a refusal.
      expect(first.succeeded, isTrue);
      expect(follower.succeeded, isTrue);
      expect(follower.jobId, second.id);
      expect(
        (await DarkroomJobsDao(db).getById(first.jobId))!.state,
        DarkroomJobState.done,
      );
      expect(
        (await DarkroomJobsDao(db).getById(follower.jobId))!.state,
        DarkroomJobState.done,
      );
    },
  );

  // The drain re-reads the `queued` table each pass, so a row an explicit
  // caller has already handed to the gate is sitting there in plain sight
  // while it waits its turn. Taking it would run one job twice — two
  // executors over one row, one cancellation id between them.
  // An orderly host shutdown mid-pass. The row must come back to the queue
  // with its start returned, so restarting the service during a dawn pass
  // costs nothing: three restarts used to burn all three attempts and fail the
  // night's job outright.
  test('an orderly shutdown hands a running pass back to the queue', () async {
    final sessionId = await insertSession();
    final image = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [image], filter: 'L');

    final service = buildService();
    final parked = Completer<void>();
    final release = Completer<void>();
    darkroom.beforeRegistry = () async {
      if (parked.isCompleted) return;
      parked.complete();
      await release.future;
    };

    final pass = service.runDawnForSession(sessionId);
    await parked.future;
    final jobs = DarkroomJobsDao(db);
    final mid = (await jobs.listByState(DarkroomJobState.running)).single;
    expect(mid.attempts, 1);

    final released = await service.releaseRunningJobsForShutdown();
    expect(released, [mid.id]);

    final handedBack = await jobs.getById(mid.id!);
    expect(handedBack!.state, DarkroomJobState.queued);
    expect(handedBack.attempts, 0, reason: 'a polite stop spends no attempt');
    expect(handedBack.startedAt, isNull);
    expect(handedBack.note, contains('orderly shutdown'));

    // The executor still in flight discovers the row moved and returns without
    // writing over the hand-back.
    release.complete();
    final outcome = await pass;
    expect(outcome.succeeded, isFalse);
    final after = await jobs.getById(mid.id!);
    expect(after!.state, DarkroomJobState.queued);
    expect(after.attempts, 0);
  });

  // The sweep reads the queue once. A pass whose `markRunning` commits just
  // after that read would be left `running` for the crash recovery to charge —
  // which is what three restarts against a freshly-drained queue actually did.
  test('a pass that starts as the host stops is handed back too', () async {
    final sessionId = await insertSession();
    final image = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [image], filter: 'L');

    final service = buildService();
    // The stop lands with the queue still empty of running rows.
    expect(await service.releaseRunningJobsForShutdown(), isEmpty);

    final outcome = await service.runDawnForSession(sessionId);
    expect(outcome.succeeded, isFalse);

    final row = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(row!.state, DarkroomJobState.queued);
    expect(row.attempts, 0, reason: 'a start the stop cancelled is not spent');
    expect(row.startedAt, isNull);
  });

  test(
    'a drain that meets a stop leaves the queue for the next start',
    () async {
      final firstNight = await insertSession();
      final firstImage = await insertSub(sessionId: firstNight);
      await insertMaster(imageIds: [firstImage], filter: 'L');
      final secondNight = await insertSession();
      final secondImage = await insertSub(sessionId: secondNight);
      await insertMaster(
        imageIds: [secondImage],
        filter: 'Ha',
        path: '${workspace.path}/M42_Ha_master.fits',
      );

      final jobs = DarkroomJobsDao(db);
      final firstJob = await jobs.enqueue(sessionId: firstNight);
      final secondJob = await jobs.enqueue(sessionId: secondNight);

      final service = buildService();
      await service.releaseRunningJobsForShutdown();
      expect(await service.drainQueue(), isEmpty);

      for (final id in [firstJob, secondJob]) {
        final row = await jobs.getById(id);
        expect(row!.state, DarkroomJobState.queued);
        expect(row.attempts, 0, reason: 'the stop spent nobody\'s start');
      }
    },
  );

  test('an orderly shutdown with no pass running writes nothing', () async {
    final sessionId = await insertSession();
    final image = await insertSub(sessionId: sessionId);
    await insertMaster(imageIds: [image], filter: 'L');

    final outcome = await buildService().runDawnForSession(sessionId);
    expect(outcome.succeeded, isTrue);

    // A separate service stands for the next launch's host, stopping with a
    // queue that holds only a finished pass.
    expect(await buildService().releaseRunningJobsForShutdown(), isEmpty);
    final row = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(
      row!.state,
      DarkroomJobState.done,
      reason: 'a finished pass is not re-queued by a later shutdown',
    );
  });

  test('the drain leaves alone a job already waiting on the gate', () async {
    final lastNight = await insertSession();
    final imageA = await insertSub(sessionId: lastNight);
    await insertMaster(imageIds: [imageA], filter: 'L');

    final otherNight = await insertSession();
    final imageB = await insertSub(sessionId: otherNight);
    await insertMaster(
      imageIds: [imageB],
      filter: 'Ha',
      path: '${workspace.path}/M42_Ha_master.fits',
    );

    final logger = LoggingService();
    final failures = <String>[];
    final logs = logger.logEntryStream.listen((entry) {
      if (entry.level == LogLevel.error) failures.add(entry.message);
    });
    addTearDown(logs.cancel);

    final service = buildService(logger: logger);
    final parked = Completer<void>();
    final release = Completer<void>();
    darkroom.beforeRegistry = () async {
      if (parked.isCompleted) return;
      parked.complete();
      await release.future;
    };

    final dawn = service.runDawnForSession(lastNight);
    await parked.future;
    final manual = service.processSessionNow(otherNight);
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if ((await DarkroomJobsDao(db).listForSession(otherNight)).isNotEmpty) {
        break;
      }
    }

    // The drain runs while that row is sitting in the `queued` table waiting
    // its turn — which is exactly when it is visible to a re-read and already
    // spoken for.
    final drained = service.drainQueue();
    release.complete();
    final outcomes = await drained;
    final first = await dawn;
    final follower = await manual;

    expect(
      outcomes.map((o) => o.jobId),
      isNot(contains(follower.jobId)),
      reason: 'the drain ran a row its submitter was already holding',
    );
    // Taking it a second time cannot silently succeed — `done` may not become
    // `running` again — so the second start fails and the drain records it as
    // a job it could not run. No such line is the proof that no second start
    // was attempted.
    expect(
      failures,
      isEmpty,
      reason: 'the drain tried to start a row another caller already held',
    );
    expect(first.succeeded, isTrue);
    expect(follower.succeeded, isTrue);
    final row = await DarkroomJobsDao(db).getById(follower.jobId);
    expect(row!.attempts, 1, reason: 'one run, not two');
  });
}
