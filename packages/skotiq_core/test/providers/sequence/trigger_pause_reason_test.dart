// Why an exposure trigger holds the run reaches the app as the step's status
// report: the run's line and the step's line say it, and the step keeps its
// frame reading.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

import '../../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart' as wire;
import 'package:skotiq_core/models.dart';

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
  test("a trigger's pause reason is the run's and the step's line", () async {
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
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    addTearDown(db.close);

    const nodeId = 'lights';
    final executor = container.read(sequenceExecutorProvider);
    executor.handleSequencerEventForTest(
      _event('InstructionProgress', {
        'node_id': nodeId,
        'instruction': 'Exposure',
        'progress_percent': 40,
        'detail': 'Frame 4/10 (120.0s)',
        'detail_kind': 'Exposure',
        'detail_json': jsonEncode({
          'frame': 4,
          'total': 10,
          'duration_secs': 120.0,
        }),
      }),
    );
    const words = 'Trigger fired: HFR above 3.0. Paused for recalibration';
    executor.handleSequencerEventForTest(
      _event('InstructionProgress', {
        'node_id': nodeId,
        'instruction': 'Exposure',
        'progress_percent': 40,
        'detail': words,
        'detail_kind': kGenericProgressDetailKind,
        'detail_json': jsonEncode(words),
      }),
    );
    executor.handleSequencerEventForTest(_event('Paused', {}));

    final progress = container.read(sequenceProgressProvider);
    expect(progress.message, 'Exposure: $words');
    expect(progress.nodeProgressDetail[nodeId], words);
    expect(
      progress.nodeProgressStructuredDetail[nodeId],
      const ExposureInstructionProgressDetail(
        frame: 4,
        total: 10,
        durationSecs: 120,
      ),
    );
    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.paused,
    );
  });

  // An operator pause after a trigger that only noted something (a filter
  // change that continues) must not read as that trigger's pause.
  test(
    "a trigger that did not pause the run is not the pause's reason",
    () async {
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
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(events.close);
      addTearDown(db.close);

      final executor = container.read(sequenceExecutorProvider);
      executor.handleSequencerEventForTest(
        _event('TriggerFired', {
          'trigger_id': 'filter_change',
          'trigger_name': 'Filter Change',
          'action': 'Continue',
        }),
      );
      expect(
        container.read(sequenceProgressProvider).message,
        'Trigger "Filter Change" fired: continue',
      );
      executor.handleSequencerEventForTest(_event('Paused', {}));

      expect(
        container.read(sequenceProgressProvider).message,
        isNot(contains('Filter Change')),
      );
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.paused,
      );
    },
  );

  test("a trigger that pauses the run stays the pause's reason", () async {
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
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    addTearDown(db.close);

    final executor = container.read(sequenceExecutorProvider);
    executor.handleSequencerEventForTest(
      _event('TriggerFired', {
        'trigger_id': 'hfr_limit',
        'trigger_name': 'HFR Limit',
        'action': 'Pause',
      }),
    );
    executor.handleSequencerEventForTest(_event('Paused', {}));

    expect(
      container.read(sequenceProgressProvider).message,
      'Trigger "HFR Limit" fired: pause the run',
    );
  });
}
