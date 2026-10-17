import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`.
///
/// The resume path pushes the entire runtime config before it gets anywhere
/// interesting, and `_seedRuntimeConfigFromSettings` rethrows its first failure.
/// Plain mocktail returns null for every unstubbed member, which surfaces as
/// a "Null is not a subtype of Future" type error and aborts the resume
/// long before the code under test — so the default here is "succeeded", and
/// tests stub only what they actually care about.
class _PermissiveBackend extends MockBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final result = super.noSuchMethod(invocation);
    return result ?? Future<void>.value();
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// A checkpoint stores the Rust-side sequence definition and a name — not a
/// Dart DB id — so a resumed run used to image against a null
/// `currentSequenceProvider`. Everything that reads the tree then degraded
/// silently: frames registered with an exposure_duration of 0.0 and no
/// gain/offset/binning/target, the Dashboard read "no sequence loaded" while the
/// run was imaging, and the run's history row had no tree to show.
///
/// The interrupted run already stored its own tree in
/// `sequence_runs.sequence_snapshot_json`, so resume recovers it from there.
void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
  });

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late SequenceRunsDao runsDao;
  late String snapshotJson;

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    backend = _PermissiveBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    runsDao = SequenceRunsDao(db);
    // A real snapshot captured from a live desktop run.
    snapshotJson = File(
      'test/fixtures/run_snapshot_sample.json',
    ).readAsStringSync();
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  test(
    'the interrupted run snapshot is the one found for its sequence name',
    () async {
      // The interrupted run: has a tree, ended non-"completed".
      final interrupted = await runsDao.startRun(
        sequenceId: null,
        sequenceName: 'CLAUDE BIN2 GAIN TEST',
        sequenceSnapshotJson: snapshotJson,
      );
      await runsDao.finishRun(interrupted, 'stopped', '{}');

      final found = await runsDao.latestSnapshotForSequenceName(
        'CLAUDE BIN2 GAIN TEST',
      );
      expect(
        found,
        equals(snapshotJson),
        reason:
            'resume must find the interrupted run\'s tree; filtering on '
            'status == completed (as the run-diff lookup does) would miss it, '
            'because an interrupted run is precisely not completed',
      );
    },
  );

  test(
    'a run with no stored snapshot is skipped, not returned as null-ish',
    () async {
      // A later resumed run that itself stored nothing must not shadow the
      // earlier run that DID store a tree.
      final withTree = await runsDao.startRun(
        sequenceId: null,
        sequenceName: 'NIGHT ONE',
        sequenceSnapshotJson: snapshotJson,
      );
      await runsDao.finishRun(withTree, 'stopped', '{}');
      await runsDao.startRun(sequenceId: null, sequenceName: 'NIGHT ONE');

      final found = await runsDao.latestSnapshotForSequenceName('NIGHT ONE');
      expect(found, equals(snapshotJson));
    },
  );

  test('an unknown sequence name yields null rather than throwing', () async {
    expect(await runsDao.latestSnapshotForSequenceName('NEVER RAN'), isNull);
  });

  /// The recovery runs BEFORE the resume flips the executor to `running`: the
  /// editor locks itself during a run, so a later `loadSequence` throws and the
  /// recovered tree is dropped — found and parsed, then discarded by the lock.
  test('the editor refuses a load once the run is marked running', () {
    final container = buildContainer();
    final sequence = SequenceFileService().parseFromMap(
      jsonDecode(snapshotJson) as Map<String, dynamic>,
    );

    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    expect(
      () => container
          .read(currentSequenceProvider.notifier)
          .loadSequence(sequence, discardUnsaved: true),
      throwsA(isA<SequenceLockedException>()),
    );

    // Idle is editable, which is the window the resume path now uses.
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.idle;
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    expect(container.read(currentSequenceProvider)?.nodes, hasLength(3));
  });
}
