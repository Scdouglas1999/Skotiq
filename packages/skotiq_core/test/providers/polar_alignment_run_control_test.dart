// Deterministic tests for the hardened standalone polar-alignment state
// machine (PolarAlignmentStateNotifier) and its config notifier. Covers the
// no-overlap ownership guarantees, truthful stop/complete semantics, robust
// wire parsing, native auto-complete persistence, and the config
// dirty-guard / save-error surfacing.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/polar_alignment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';

import '../mocks/mock_backend.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void swapTo(SkotiqBackend backend) => state = backend;
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

Future<void> _pump([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SkotiqEvent _statusEvent(String phase, {String status = ''}) =>
    SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.polarAlignment,
      eventType: 'PolarAlignmentStatus',
      data: {'status': status, 'phase': phase, 'point': 0},
    );

SkotiqEvent _errorEvent({
  num azimuth = 5,
  num altitude = 5,
  num total = 7,
}) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.polarAlignment,
  eventType: 'PolarAlignment',
  data: {
    'azimuth_error': azimuth,
    'altitude_error': altitude,
    'total_error': total,
  },
);

SkotiqEvent _imageEvent(Object? imageData, {Object? solvedRa}) =>
    SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.polarAlignment,
      eventType: 'PolarAlignmentImage',
      data: {
        'image_data': imageData,
        'width': 4,
        'height': 2,
        if (solvedRa != null) 'solved_ra': solvedRa,
      },
    );

/// Stub `startPolarAlignment` (all named args matched) to run [body].
void _whenStartTppa(
  SkotiqBackend backend,
  Future<void> Function(Invocation) body,
) {
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
  ).thenAnswer(body);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<SkotiqEvent> events;
  late MockBackend backend;
  late SkotiqDatabase database;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(() => backend.stopPolarAlignment()).thenAnswer((_) async {});
    _whenStartTppa(backend, (_) async {});
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await events.close();
    // Some tests intentionally close the DB mid-test to force a write failure.
    try {
      await database.close();
    } catch (_) {}
  });

  ProviderContainer buildContainer({SkotiqBackend? initial}) {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, initial ?? backend),
        ),
        databaseProvider.overrideWithValue(database),
        // No active profile: capability resolution + profileId are null.
        activeEquipmentProfileProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  const config = PolarAlignmentConfig();

  Future<void> enterAdjusting(
    ProviderContainer container,
    PolarAlignmentStateNotifier notifier,
  ) async {
    await notifier.startAlignment(config);
    events.add(_statusEvent('adjusting'));
    await _pump();
    events.add(_errorEvent());
    await _pump();
  }

  group('wire payload parsing', () {
    test('List<dynamic> bytes + int solved_ra parse into a preview', () async {
      final container = buildContainer();
      container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      // JSON delivers a List<dynamic> of ints and an integer solved_ra.
      events.add(_imageEvent(<dynamic>[10, 20, 30], solvedRa: 5));
      await _pump();

      final state = container.read(polarAlignmentStateProvider);
      expect(state.imageData, isNotNull);
      expect(state.imageData, equals(Uint8List.fromList([10, 20, 30])));
      expect(state.solvedRa, 5.0);
    });

    test(
      'malformed image payload is ignored without killing the stream',
      () async {
        final container = buildContainer();
        final notifier = container.read(polarAlignmentStateProvider.notifier);
        await _pump();

        // First a good frame.
        events.add(_imageEvent(<dynamic>[1, 2, 3]));
        await _pump();
        // Then a structurally-invalid payload (a Map, not bytes).
        events.add(_imageEvent(<String, dynamic>{'not': 'bytes'}));
        await _pump();

        // Prior preview retained (not blanked, no crash).
        expect(
          container.read(polarAlignmentStateProvider).imageData,
          equals(Uint8List.fromList([1, 2, 3])),
        );

        // Subscription still alive: a subsequent good frame updates.
        events.add(_imageEvent(<dynamic>[9, 9]));
        await _pump();
        expect(
          container.read(polarAlignmentStateProvider).imageData,
          equals(Uint8List.fromList([9, 9])),
        );
        // Keep the notifier referenced.
        expect(notifier, isNotNull);
      },
    );
  });

  test('stale event after backend swap cannot mutate state', () async {
    final oldBackend = backend;
    final oldEvents = events;
    final newBackend = MockBackend();
    final newEvents = StreamController<SkotiqEvent>.broadcast();
    addTearDown(newEvents.close);
    when(() => newBackend.eventStream).thenAnswer((_) => newEvents.stream);

    final container = buildContainer(initial: oldBackend);
    container.read(polarAlignmentStateProvider.notifier);
    await _pump();

    (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
        .swapTo(newBackend);
    await _pump();

    // An event from the superseded backend after the swap must be ignored.
    oldEvents.add(_errorEvent(total: 42));
    await _pump();
    expect(container.read(polarAlignmentStateProvider).currentError, isNull);

    // The new backend still drives state.
    newEvents.add(_errorEvent(total: 3));
    await _pump();
    expect(
      container.read(polarAlignmentStateProvider).currentError!.totalError,
      3.0,
    );
  });

  test(
    'backend swap abandons stale run without stopping the new host',
    () async {
      final oldBackend = backend;
      final newBackend = MockBackend();
      final newEvents = StreamController<SkotiqEvent>.broadcast();
      addTearDown(newEvents.close);
      when(() => newBackend.eventStream).thenAnswer((_) => newEvents.stream);
      _whenStartTppa(newBackend, (_) async {});

      final container = buildContainer(initial: oldBackend);
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await enterAdjusting(container, notifier);

      (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
          .swapTo(newBackend);
      await _pump();

      final switchedState = container.read(polarAlignmentStateProvider);
      expect(switchedState.phase, PolarAlignPhase.error);
      expect(switchedState.errorMessage, contains('previous host'));

      // The superseded run no longer owns this controller, so Stop is a local
      // no-op and never a command redirected to the newly connected rig.
      await notifier.stopAlignment();
      verifyNever(() => newBackend.stopPolarAlignment());

      // Retained measurements are diagnostic only; they cannot authorize a
      // Complete command against the replacement host either.
      await expectLater(
        notifier.completeAlignment(),
        throwsA(isA<StateError>()),
      );
      verifyNever(() => newBackend.stopPolarAlignment());

      // Stale ownership must not permanently block work on the new host.
      await notifier.startAlignment(config);
      verify(
        () => newBackend.startPolarAlignment(
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
      ).called(1);
    },
  );

  test('backend swap during Start cannot redirect admission', () async {
    final startGate = Completer<void>();
    _whenStartTppa(backend, (_) => startGate.future);

    final newBackend = MockBackend();
    final newEvents = StreamController<SkotiqEvent>.broadcast();
    addTearDown(newEvents.close);
    when(() => newBackend.eventStream).thenAnswer((_) => newEvents.stream);
    _whenStartTppa(newBackend, (_) async {});

    final container = buildContainer();
    final notifier = container.read(polarAlignmentStateProvider.notifier);
    await _pump();

    final start = notifier.startAlignment(config);
    await _pump();
    (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
        .swapTo(newBackend);
    await _pump();

    startGate.complete();
    await expectLater(
      start,
      throwsA(isA<PolarAlignmentBackendChangedException>()),
    );
    verifyNever(
      () => newBackend.startPolarAlignment(
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
    );
    expect(
      container.read(polarAlignmentStateProvider).errorMessage,
      contains('previous host'),
    );
  });

  group('start admission (no overlap)', () {
    test('rapid double Start rejects the second deterministically', () async {
      final gate = Completer<void>();
      var startCount = 0;
      _whenStartTppa(backend, (_) async {
        startCount++;
        await gate.future;
      });

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      final first = notifier.startAlignment(config);
      await _pump(); // let the first reach the (gated) backend start

      await expectLater(
        notifier.startAlignment(config),
        throwsA(isA<PolarAlignmentBusyException>()),
      );

      gate.complete();
      await first;
      expect(startCount, 1);
    });

    test('Start during an in-flight stop waits (no overlap)', () async {
      final stopGate = Completer<void>();
      var startCount = 0;
      _whenStartTppa(backend, (_) async => startCount++);
      when(
        () => backend.stopPolarAlignment(),
      ).thenAnswer((_) async => stopGate.future);

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      await notifier.startAlignment(config); // owns hardware
      expect(startCount, 1);

      final stopFuture = notifier.stopAlignment();
      await _pump();
      final restart = notifier.startAlignment(config);
      await _pump();

      // The restart must NOT have issued a backend start while stop is pending.
      expect(startCount, 1);

      stopGate.complete();
      await stopFuture;
      await restart;
      expect(startCount, 2); // only after stop settled
    });
  });

  group('stop semantics', () {
    test('stop during Start waits for admission before stopping', () async {
      final startGate = Completer<void>();
      var stopCount = 0;
      _whenStartTppa(backend, (_) => startGate.future);
      when(() => backend.stopPolarAlignment()).thenAnswer((_) async {
        stopCount++;
      });

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      final start = notifier.startAlignment(config);
      await _pump();
      final stop = notifier.stopAlignment();
      await _pump();

      // Stop must not race ahead of the backend's start acknowledgement.
      expect(stopCount, 0);

      startGate.complete();
      await Future.wait([start, stop]);
      expect(stopCount, 1);
      expect(
        container.read(polarAlignmentStateProvider).phase,
        PolarAlignPhase.idle,
      );
    });

    test('two stops during Start still issue one backend stop', () async {
      final startGate = Completer<void>();
      final stopGate = Completer<void>();
      var stopCount = 0;
      _whenStartTppa(backend, (_) => startGate.future);
      when(() => backend.stopPolarAlignment()).thenAnswer((_) async {
        stopCount++;
        await stopGate.future;
      });

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      final start = notifier.startAlignment(config);
      await _pump();
      final firstStop = notifier.stopAlignment();
      final secondStop = notifier.stopAlignment();
      await _pump();
      expect(stopCount, 0);

      startGate.complete();
      await start;
      await _pump();
      expect(stopCount, 1);

      stopGate.complete();
      await Future.wait([firstStop, secondStop]);
      expect(stopCount, 1);
    });

    test('stop awaits a delayed task and only then publishes idle', () async {
      final stopGate = Completer<void>();
      when(
        () => backend.stopPolarAlignment(),
      ).thenAnswer((_) async => stopGate.future);

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await notifier.startAlignment(config);

      final stopFuture = notifier.stopAlignment();
      await _pump();
      // Not idle yet — stop is still awaiting the backend.
      expect(
        container.read(polarAlignmentStateProvider).phase,
        isNot(PolarAlignPhase.idle),
      );

      stopGate.complete();
      await stopFuture;
      expect(
        container.read(polarAlignmentStateProvider).phase,
        PolarAlignPhase.idle,
      );
    });

    test('stop failure stays active, retryable, and blocks restart', () async {
      when(
        () => backend.stopPolarAlignment(),
      ).thenThrow(StateError('stop failed'));

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await notifier.startAlignment(config);

      await expectLater(notifier.stopAlignment(), throwsA(isA<StateError>()));
      expect(
        container.read(polarAlignmentStateProvider).phase,
        PolarAlignPhase.measuring,
      );
      expect(container.read(polarAlignmentStateProvider).isRunning, isTrue);
      expect(
        container.read(polarAlignmentStateProvider).statusMessage,
        contains('retry'),
      );

      // Run still owns the hardware — a restart is rejected.
      await expectLater(
        notifier.startAlignment(config),
        throwsA(isA<PolarAlignmentBusyException>()),
      );
    });

    test('concurrent stop is idempotent (backend stopped once)', () async {
      final stopGate = Completer<void>();
      var stopCount = 0;
      when(() => backend.stopPolarAlignment()).thenAnswer((_) async {
        stopCount++;
        await stopGate.future;
      });

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await notifier.startAlignment(config);

      final a = notifier.stopAlignment();
      final b = notifier.stopAlignment();
      await _pump();
      stopGate.complete();
      await Future.wait([a, b]);
      expect(stopCount, 1);
    });
  });

  group('complete semantics (no false success)', () {
    test(
      'concurrent Complete calls share one stop and history write',
      () async {
        final stopGate = Completer<void>();
        var stopCount = 0;
        when(() => backend.stopPolarAlignment()).thenAnswer((_) async {
          stopCount++;
          await stopGate.future;
        });

        final container = buildContainer();
        final notifier = container.read(polarAlignmentStateProvider.notifier);
        await _pump();
        await enterAdjusting(container, notifier);

        final first = notifier.completeAlignment();
        final second = notifier.completeAlignment();
        await _pump();
        expect(stopCount, 1);

        stopGate.complete();
        await Future.wait([first, second]);
        expect(stopCount, 1);
        final rows = await database.polarAlignmentHistoryDao
            .getHistoryForProfile(null);
        expect(rows, hasLength(1));
      },
    );

    test(
      'Stop during Complete joins completion instead of stopping twice',
      () async {
        final stopGate = Completer<void>();
        var stopCount = 0;
        when(() => backend.stopPolarAlignment()).thenAnswer((_) async {
          stopCount++;
          await stopGate.future;
        });

        final container = buildContainer();
        final notifier = container.read(polarAlignmentStateProvider.notifier);
        await _pump();
        await enterAdjusting(container, notifier);

        final complete = notifier.completeAlignment();
        await _pump();
        final stop = notifier.stopAlignment();
        await _pump();
        expect(stopCount, 1);

        stopGate.complete();
        await Future.wait([complete, stop]);
        expect(stopCount, 1);
        expect(
          container.read(polarAlignmentStateProvider).phase,
          PolarAlignPhase.complete,
        );
      },
    );

    test(
      'complete with missing measurement throws and saves nothing',
      () async {
        final container = buildContainer();
        final notifier = container.read(polarAlignmentStateProvider.notifier);
        await _pump();
        await notifier.startAlignment(config); // measuring, no errors yet

        await expectLater(
          notifier.completeAlignment(),
          throwsA(isA<StateError>()),
        );
        expect(
          container.read(polarAlignmentStateProvider).phase,
          PolarAlignPhase.measuring,
        );
        expect(container.read(polarAlignmentStateProvider).isRunning, isTrue);
        // Never even attempted to stop the backend.
        verifyNever(() => backend.stopPolarAlignment());
        final rows = await database.polarAlignmentHistoryDao
            .getHistoryForProfile(null);
        expect(rows, isEmpty);
      },
    );

    test(
      'complete with a failing stop does not persist or mark success',
      () async {
        when(
          () => backend.stopPolarAlignment(),
        ).thenThrow(StateError('stop failed'));

        final container = buildContainer();
        final notifier = container.read(polarAlignmentStateProvider.notifier);
        await _pump();
        await enterAdjusting(container, notifier); // valid measurements

        await expectLater(
          notifier.completeAlignment(),
          throwsA(isA<StateError>()),
        );
        expect(
          container.read(polarAlignmentStateProvider).phase,
          PolarAlignPhase.adjusting,
        );
        expect(container.read(polarAlignmentStateProvider).isRunning, isTrue);
        final rows = await database.polarAlignmentHistoryDao
            .getHistoryForProfile(null);
        expect(rows, isEmpty);
      },
    );

    test(
      'history failure after a successful stop is terminal and retry-safe',
      () async {
        final container = buildContainer();
        final notifier = container.read(polarAlignmentStateProvider.notifier);
        await _pump();
        await enterAdjusting(container, notifier);
        await database.customStatement('DROP TABLE polar_alignment_history');

        await expectLater(notifier.completeAlignment(), throwsA(anything));

        final failed = container.read(polarAlignmentStateProvider);
        expect(failed.phase, PolarAlignPhase.error);
        expect(failed.isRunning, isFalse);
        expect(failed.errorMessage, contains('could not be saved'));
        expect(notifier.reset, returnsNormally);
      },
    );
  });

  test(
    'native auto-complete persists exactly one autoCompleted record',
    () async {
      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await enterAdjusting(container, notifier);

      // Native emits a terminal 'complete' status (threshold reached).
      events.add(_statusEvent('complete', status: 'Complete!'));
      await _pump();
      // A repeat 'complete' must not double-save.
      events.add(_statusEvent('complete', status: 'Complete!'));
      await _pump();

      expect(
        container.read(polarAlignmentStateProvider).phase,
        PolarAlignPhase.complete,
      );
      final rows = await database.polarAlignmentHistoryDao.getHistoryForProfile(
        null,
      );
      expect(rows.length, 1);
      expect(rows.single.autoCompleted, isTrue);
    },
  );

  test(
    'native auto-complete racing manual Complete saves one record',
    () async {
      final stopGate = Completer<void>();
      var stopCount = 0;
      when(() => backend.stopPolarAlignment()).thenAnswer((_) async {
        stopCount++;
        await stopGate.future;
      });

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await enterAdjusting(container, notifier);

      final complete = notifier.completeAlignment();
      await _pump();
      events.add(_statusEvent('complete', status: 'Threshold reached'));
      await _pump();

      stopGate.complete();
      await complete;
      expect(stopCount, 1);
      final rows = await database.polarAlignmentHistoryDao.getHistoryForProfile(
        null,
      );
      expect(rows, hasLength(1));
    },
  );

  test(
    'remote completion never writes the controller local database',
    () async {
      final remote = _MockNetworkBackend();
      when(() => remote.eventStream).thenAnswer((_) => events.stream);
      _whenStartTppa(remote, (_) async {});
      when(() => remote.stopPolarAlignment()).thenAnswer((_) async {});
      when(
        () => remote.fetchPolarAlignmentHistory(equipmentProfileId: null),
      ).thenAnswer((_) async => const RemotePage(items: [], total: 0));
      final container = buildContainer(initial: remote);
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();
      await enterAdjusting(container, notifier);

      await notifier.completeAlignment();

      final localRows = await database.polarAlignmentHistoryDao
          .getHistoryForProfile(null);
      expect(localRows, isEmpty);
    },
  );

  test('reset rejects while starting or while hardware is owned', () async {
    final startGate = Completer<void>();
    _whenStartTppa(backend, (_) => startGate.future);

    final container = buildContainer();
    final notifier = container.read(polarAlignmentStateProvider.notifier);
    await _pump();

    final start = notifier.startAlignment(config);
    await _pump();
    expect(notifier.reset, throwsA(isA<PolarAlignmentBusyException>()));

    startGate.complete();
    await start;
    expect(notifier.reset, throwsA(isA<PolarAlignmentBusyException>()));

    await notifier.stopAlignment();
    expect(notifier.reset, returnsNormally);
  });

  test(
    'Pole start mode flows startFromCurrent=false through to the backend',
    () async {
      bool? captured;
      _whenStartTppa(backend, (invocation) async {
        captured = invocation.namedArguments[#startFromCurrent] as bool?;
      });

      final container = buildContainer();
      final notifier = container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      await notifier.startAlignment(config.copyWith(startFromCurrent: false));
      expect(captured, isFalse);
    },
  );

  group('config notifier', () {
    test(
      'a dirty edit during load is not clobbered by the stale load',
      () async {
        // Seed a persisted config (exposure 9) that the load will read.
        await database.settingsDao.setSetting(
          'polar_alignment_config',
          '{"exposureTime":9.0}',
        );

        final container = buildContainer();
        final notifier = container.read(polarAlignmentConfigProvider.notifier);
        // Edit in the same tick, before the async load resolves.
        final edit = notifier.updateConfig(
          const PolarAlignmentConfig(exposureTime: 3.0),
        );
        await edit;
        await _pump();

        // The user's edit wins; the stale on-disk 9.0 did not overwrite it.
        expect(container.read(polarAlignmentConfigProvider).exposureTime, 3.0);
      },
    );

    test('save failure surfaces (rethrows + error provider set)', () async {
      final container = buildContainer();
      final notifier = container.read(polarAlignmentConfigProvider.notifier);
      await _pump();

      // Break persistence: a closed database throws on write.
      await database.close();

      await expectLater(
        notifier.updateConfig(const PolarAlignmentConfig(exposureTime: 7.0)),
        throwsA(anything),
      );
      expect(container.read(polarAlignmentConfigSaveErrorProvider), isNotNull);
    });
  });
}
