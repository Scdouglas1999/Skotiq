// Pressing Stop on a polar-alignment run must be answered on screen.
//
// Unacknowledged, Stop at "Plate solving point 1/3…" produces no change of any
// kind — same status, same button, elapsed counter still climbing — and the run
// then ends in the error state on the solver's own 30 s timeout, so the screen
// blames the solver for a run the user stopped. The teardown itself is bounded
// (the backend stop awaits real termination), but a bounded teardown with no
// acknowledgement is indistinguishable from a click that was dropped.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/polar_alignment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';

import '../mocks/mock_backend.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }
}

Future<void> _pump([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SkotiqEvent _statusEvent(String phase, {String status = ''}) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.polarAlignment,
  eventType: 'PolarAlignmentStatus',
  data: {'status': status, 'phase': phase, 'point': 1},
);

void _whenStartTppa(SkotiqBackend backend) {
  when(
    () => backend.startPolarAlignment(
      exposureTime: any(named: 'exposureTime'),
      stepSize: any(named: 'stepSize'),
      binning: any(named: 'binning'),
      isNorth: any(named: 'isNorth'),
      manualRotation: any(named: 'manualRotation'),
      rotateEast: any(named: 'rotateEast'),
      gain: any(named: 'gain'),
      offset: any(named: 'offset'),
      solveTimeout: any(named: 'solveTimeout'),
      startFromCurrent: any(named: 'startFromCurrent'),
      autoCompleteThreshold: any(named: 'autoCompleteThreshold'),
    ),
  ).thenAnswer((_) async {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<SkotiqEvent> events;
  late MockBackend backend;
  late SkotiqDatabase database;
  late Completer<void> stopLanded;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = MockBackend();
    stopLanded = Completer<void>();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    // A real teardown takes seconds: the host signals the run, waits for the
    // task to reach a checkpoint, and only then answers.
    when(
      () => backend.stopPolarAlignment(),
    ).thenAnswer((_) => stopLanded.future);
    _whenStartTppa(backend);
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await events.close();
    await database.close();
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        databaseProvider.overrideWithValue(database),
        activeEquipmentProfileProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  const config = PolarAlignmentConfig();

  test('a stop is acknowledged before the host answers', () async {
    final container = buildContainer();
    final notifier = container.read(polarAlignmentStateProvider.notifier);
    await notifier.startAlignment(config);
    events.add(_statusEvent('measuring', status: 'Plate solving point 1/3...'));
    await _pump();
    expect(
      container.read(polarAlignmentStateProvider).statusMessage,
      'Plate solving point 1/3...',
    );

    final stopping = notifier.stopAlignment();
    await _pump();

    final state = container.read(polarAlignmentStateProvider);
    expect(
      state.statusMessage.toLowerCase(),
      contains('stopping'),
      reason: 'the click must be visibly received while teardown is in flight',
    );
    expect(
      state.isRunning,
      isTrue,
      reason: 'the run still owns the hardware until the host confirms',
    );

    stopLanded.complete();
    await stopping;
    await _pump();
    expect(
      container.read(polarAlignmentStateProvider).phase,
      PolarAlignPhase.idle,
    );
  });

  test('a stop still in flight is not reported as a run failure', () async {
    final container = buildContainer();
    final notifier = container.read(polarAlignmentStateProvider.notifier);
    await notifier.startAlignment(config);
    events.add(_statusEvent('measuring', status: 'Plate solving point 1/3...'));
    await _pump();

    final stopping = notifier.stopAlignment();
    await _pump();

    // The run reaches its checkpoint by failing the solve it was blocked on.
    // The user asked for this run to end; the solver is not the story.
    events.add(
      _statusEvent(
        'error',
        status: 'Error: Plate solve timed out after 30.0 seconds for point 1',
      ),
    );
    await _pump();
    expect(
      container.read(polarAlignmentStateProvider).phase,
      isNot(PolarAlignPhase.error),
      reason: 'a stopped run must not present as a failed one',
    );

    stopLanded.complete();
    await stopping;
    await _pump();

    final state = container.read(polarAlignmentStateProvider);
    expect(state.phase, PolarAlignPhase.idle);
    expect(state.errorMessage, isNull);
    expect(state.statusMessage, 'Polar alignment stopped');
  });
}
