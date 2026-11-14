// The SequenceExecutor's FrameAccepted handling consumes the `save_path` field
// the Rust grader emits on accepted frames.
//
// `_registerSequenceFrame` leaving `file_path` blank for accepted frames shows
// a colour-bordered placeholder tile in the thumbnail strip.
//
// Accepted frames carry the on-disk save path via the `save_path` field on
// `SequencerEvent::FrameAccepted` → `event.data`, and the inserted
// `captured_images` row's `file_path` column holds it, so the thumbnail strip
// renders the inline preview the same way it does for rejected frames via the
// existing `reject_path` flow.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/sequencer_wire.dart';
import '../../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart'
    as bridge_event;

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
  });

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late ImagesDao imagesDao;

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
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  test(
    'FrameAccepted with save_path inserts captured_images row with file_path',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      const savePath = '/captures/m31/L_0001.fits';

      // Pump the event through the same handler the live native event
      // subscription uses. We don't need to spin up the Rust backend
      // because the FrameAccepted path is entirely Dart-side once the
      // event lands in `_handleSequencerEvent`.
      executor.handleSequencerEventForTest(
        frameVerdictEvent(
          accepted: true,
          nodeId: 'exposure-node-1',
          frame: 1,
          total: 10,
          hfr: 2.35,
          starCount: 145,
          path: savePath,
        ),
      );

      // Let the fire-and-forget `unawaited(insertSequenceFrame(...))`
      // complete.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final rows = await imagesDao.getImagesByProducingNode(
          producingNodeId: 'exposure-node-1',
        );
        if (rows.isNotEmpty) {
          // Assert the row was tagged correctly and the path landed.
          expect(rows, hasLength(1));
          final row = rows.single;
          expect(
            row.filePath,
            equals(savePath),
            reason:
                'accepted frame must persist save_path → file_path; the thumbnail strip relies on this for the inline preview',
          );
          expect(row.fileName, equals('L_0001.fits'));
          expect(row.isAccepted, isTrue);
          expect(row.runtimeGrade, equals('pass'));
          expect(row.hfr, closeTo(2.35, 1e-9));
          expect(row.starCount, equals(145));
          expect(row.producingNodeId, equals('exposure-node-1'));
          return;
        }
      }
      fail('captured_images row for accepted frame was never written');
    },
  );

  /// The Dashboard's Recent Frames tile renders
  /// `recentSessionFramesProvider`, which on the host IS the in-memory
  /// `sessionImagesProvider` list. Only the ad-hoc capture loop appended to it,
  /// so a sequenced night showed "No frames captured this session yet" from dusk
  /// to dawn while frames were landing on disk and in the database.
  test('accepted sequence frame also lands in the live session list', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);

    expect(container.read(sessionImagesProvider), isEmpty);

    executor.handleSequencerEventForTest(
      frameVerdictEvent(
        accepted: true,
        nodeId: 'exposure-node-live',
        frame: 1,
        total: 3,
        hfr: 3.1,
        starCount: 88,
        path: '/captures/m42/L_0007.fits',
      ),
    );

    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final live = container.read(sessionImagesProvider);
      if (live.isNotEmpty) {
        expect(live, hasLength(1));
        expect(live.single.filePath, equals('/captures/m42/L_0007.fits'));
        return;
      }
    }
    fail(
      'accepted sequence frame never reached sessionImagesProvider, so the '
      'Dashboard Recent Frames tile would stay empty for the whole run',
    );
  });

  test(
    'rejected sequence frame is NOT added to the live session list',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      executor.handleSequencerEventForTest(
        frameVerdictEvent(
          accepted: false,
          nodeId: 'exposure-node-reject',
          frame: 2,
          total: 3,
          path: '/captures/m42/Reject/L_0008.fits',
          reason: 'HFR 6.2 above limit',
        ),
      );

      // Wait for the row to persist, then assert the live list stayed empty: a
      // reject has no "rejected" affordance in the plain strip, so showing it
      // there would read as a good frame.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final rows = await imagesDao.getImagesByProducingNode(
          producingNodeId: 'exposure-node-reject',
        );
        if (rows.isNotEmpty) {
          expect(rows.single.isAccepted, isFalse);
          expect(container.read(sessionImagesProvider), isEmpty);
          return;
        }
      }
      fail('captured_images row for rejected frame was never written');
    },
  );

  test(
    'a FrameAccepted with no saved file still gets a row, with an empty path',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      executor.handleSequencerEventForTest(
        frameVerdictEvent(
          accepted: true,
          nodeId: 'exposure-node-legacy',
          frame: 1,
          total: 1,
        ),
      );

      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final rows = await imagesDao.getImagesByProducingNode(
          producingNodeId: 'exposure-node-legacy',
        );
        if (rows.isNotEmpty) {
          final row = rows.single;
          expect(
            row.filePath,
            isEmpty,
            reason:
                'a frame without a save_path must still insert the row '
                '(with an empty file_path) so the strip can show its '
                'color-bordered placeholder tile rather than skipping',
          );
          expect(row.isAccepted, isTrue);
          return;
        }
      }
      fail('captured_images row for the unsaved frame was never written');
    },
  );
}
