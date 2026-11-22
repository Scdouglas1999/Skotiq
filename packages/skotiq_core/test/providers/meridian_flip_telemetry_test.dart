import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _Backend extends BackendNotifier {
  _Backend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  test('native step names resolve to the Dart steps', () {
    expect(
      flipStepFromNativeName('EnablingTracking'),
      FlipStep.enablingTracking,
    );
    expect(
      flipStepFromNativeName('VerifyingPierSide'),
      FlipStep.verifyingPierSide,
    );
    expect(FlipStep.enablingTracking.displayName, 'Turning tracking on');
    expect(FlipStep.confirmingTracking.displayName, 'Confirming tracking');
  });

  test('a host progress event updates the shared flip state', () async {
    final backend = MockBackend();
    final events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _Backend(ref, backend)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(meridianFlipTelemetryProvider, (_, __) {});

    events.add(
      _progress(
        '{"Starting":{"target_name":"M42","from_pier_side":"East","hour_angle":0.2}}',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(flipExecutionStateProvider),
      FlipExecutionState.executing,
    );

    events.add(
      _progress(
        '{"StepStarted":{"step":"EnablingTracking","step_index":1,"total_steps":4}}',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(flipCurrentStepProvider), FlipStep.enablingTracking);
    expect(
      container.read(flipCurrentStepProvider)!.displayName,
      'Turning tracking on',
    );
  });

  // P10 left: a native Failed set the state and the error and left the step
  // and percent, so a flip refused before it started (a configuration error
  // is reported before Starting) read "Failed, attempt 1, 100%" from the flip
  // before it.
  group('a flip that ends', () {
    late ProviderContainer container;
    late StreamController<SkotiqEvent> events;

    setUp(() {
      final backend = MockBackend();
      events = StreamController<SkotiqEvent>.broadcast();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) => _Backend(ref, backend)),
        ],
      );
      container.listen(meridianFlipTelemetryProvider, (_, __) {});
    });

    tearDown(() async {
      container.dispose();
      await events.close();
    });

    Future<void> send(List<String> details) async {
      for (final detail in details) {
        events.add(_progress(detail));
      }
      await Future<void>.delayed(Duration.zero);
    }

    FlipMonitorProgress shown() => FlipMonitorProgress(
      state: container.read(flipExecutionStateProvider),
      attempt: container.read(flipCurrentAttemptProvider),
      step: container.read(flipCurrentStepProvider),
      percent: container.read(flipProgressProvider),
      error: container.read(flipLastErrorProvider),
    );

    const completedFlip = [
      '{"Starting":{"target_name":"M31","from_pier_side":"East","hour_angle":0.25}}',
      '{"StepStarted":{"step":"SlewingToTarget","step_index":2,"total_steps":9}}',
      '{"Progress":{"percent":40}}',
      '{"Completed":{"new_pier_side":"West","duration_secs":185.0}}',
    ];

    test('before it started shows no step or progress of the flip before '
        'it', () async {
      await send(completedFlip);
      await send([
        '{"Failed":{"error":"retry delays missing","action_taken":"parked"}}',
      ]);

      expect(shown().toJson(), {
        'state': 'failed',
        'attempt': 0,
        'step': null,
        'progress': 0,
        'error': 'retry delays missing',
      });
    });

    test('aborted before it started shows none either', () async {
      await send(completedFlip);
      await send(['{"Aborted":{"reason":"a sequence owns the mount"}}']);

      expect(shown().toJson(), {
        'state': 'aborted',
        'attempt': 0,
        'step': null,
        'progress': 0,
        'error': 'a sequence owns the mount',
      });
    });

    test('mid-way keeps the step, attempt and progress it reached', () async {
      await send([
        completedFlip[0],
        completedFlip[1],
        completedFlip[2],
        '{"StepFailed":{"step":"SlewingToTarget","error":"slew timed out"}}',
        '{"Failed":{"error":"pier side did not change","action_taken":"parked"}}',
      ]);

      expect(shown().toJson(), {
        'state': 'failed',
        'attempt': 1,
        'step': 'slewingToTarget',
        'progress': 40,
        'error': 'pier side did not change',
      });
    });
  });
}

SkotiqEvent _progress(String detailJson) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  eventType: 'InstructionProgress',
  data: {'detail_kind': 'MeridianFlip', 'detail_json': detailJson},
);
