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
}

SkotiqEvent _progress(String detailJson) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  eventType: 'InstructionProgress',
  data: {'detail_kind': 'MeridianFlip', 'detail_json': detailJson},
);
