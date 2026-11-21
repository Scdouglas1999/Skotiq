// A native Center step publishes the solve the Imaging screen and the
// runtime mirror already read. RA on the wire is hours.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart' as wire;

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

wire.SkotiqEvent _event(String type, Map<String, Object?> data) {
  return wire.SkotiqEvent(
    timestamp: DateTime.utc(2026, 11, 21).millisecondsSinceEpoch,
    severity: wire.EventSeverity.info,
    category: wire.EventCategory.sequencer,
    eventType: type,
    data: data,
  );
}

void main() {
  test('a Center solve sets the offset and the plate-solve position', () async {
    final backend = MockBackend();
    final events = StreamController<wire.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith((ref) => _TestBackendNotifier(ref, backend)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    addTearDown(db.close);

    const nodeId = 'center-1';
    container.read(runRecordProvider.notifier).updateProgress(
      currentNodeId: nodeId,
    );
    final executor = container.read(sequenceExecutorProvider);
    executor.handleSequencerEventForTest(
      _event('InstructionProgress', {
        'node_id': nodeId,
        'instruction': 'Center',
        'progress_percent': 40,
        'detail': 'attempt 2',
        'detail_kind': 'Center',
        'detail_json': jsonEncode({
          'attempt': 2,
          'max_attempts': 5,
          'last_separation_arcsec': 12.5,
          'solved_ra_hours': 5.5,
          'solved_dec_degrees': 24.1,
        }),
      }),
    );

    final centering = container.read(centeringStatusProvider);
    expect(centering.currentOffsetArcsec, 12.5);
    expect(centering.currentIteration, 2);
    final solve = container.read(plateSolveStateProvider).lastResult!;
    expect(solve.ra, 5.5 * 15);
    final mirrored = decodePlateSolveResult(encodePlateSolveResult(solve));
    expect(mirrored.ra, solve.ra);
    expect(mirrored.dec, solve.dec);
    expect(mirrored.pixelScale.isNaN, isTrue);
    expect(mirrored.cd11.isNaN, isTrue);
    expect(samePlateSolveOutcome(solve, mirrored), isTrue);
    expect(solve.dec, 24.1);
    expect(solve.cd11, isNot(0));
    expect(solve.cd12.isNaN, isTrue);
    expect(solve.cd21.isNaN, isTrue);
    expect(solve.cd22.isNaN, isTrue);

    executor.handleSequencerEventForTest(
      _event('NodeCompleted', {'node_id': nodeId, 'status': 'failed'}),
    );
    expect(
      container.read(centeringStatusProvider).state,
      CenteringState.error,
    );
    expect(container.read(plateSolveStateProvider).lastResult, isNull);
    expect(container.read(plateSolveStateProvider).isSolving, isFalse);
  });
}
