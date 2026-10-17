// A target the operator named but never gave coordinates used to validate
// clean. `TargetHeaderNode` is born at exactly RA 0h / Dec +0°, both values
// are in range, so `TargetCoordinatesRule` passed it and `start()` ran. The
// runtime stamps that placeholder onto the whole subtree, so an unattended
// run slewed to a spot in Pisces and recorded every frame as "M31".
//
// These tests drive the real start path — SequenceExecutor.start() ->
// validateSequenceForStart() -> sequenceValidatorProvider -> the shared
// `defaultSequenceValidators` registry. Nothing here constructs the rule
// directly, so dropping it from the registry has to make them fail.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`,
/// so a start that gets past validation runs end to end without stubbing the
/// whole runtime-config push.
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

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._state);
  final AppSettingsState _state;

  @override
  Future<AppSettingsState> build() async => _state;
}

/// Validator wired to the PRODUCTION structural registry. The ref-aware and
/// async tiers are dropped because they want a connected rig and a dark
/// library; `defaultSequenceValidators` is the list under test.
SequenceValidatorService _registryValidator(Ref ref) =>
    SequenceValidatorService(
      ref: ref,
      syncRules: defaultSequenceValidators,
      refAwareRules: const [],
      asyncRules: const [],
    );

/// One target named "M31" holding a Slew that inherits the target pointing
/// plus an exposure. [childrenEnabled] false leaves the placeholder with
/// nothing under it that can reach the mount.
Sequence _sequenceWithTarget({
  required double raHours,
  required double decDegrees,
  bool childrenEnabled = true,
}) {
  final slew = SlewNode(
    id: 'slew',
    parentId: 'target',
    isEnabled: childrenEnabled,
    useTargetCoords: true,
  );
  final exposure = ExposureNode(
    id: 'exposure',
    parentId: 'target',
    orderIndex: 1,
    isEnabled: childrenEnabled,
    durationSecs: 5,
    count: 2,
  );
  final target = TargetHeaderNode(
    id: 'target',
    parentId: 'root',
    targetName: 'M31',
    raHours: raHours,
    decDegrees: decDegrees,
    childIds: const ['slew', 'exposure'],
  );
  final root = InstructionSetNode(
    id: 'root',
    name: 'Sequence',
    childIds: const ['target'],
  );
  return Sequence.create(
    name: 'coordinate gate',
    nodes: {
      root.id: root,
      target.id: target,
      slew.id: slew,
      exposure.id: exposure,
    },
    rootNodeId: root.id,
  );
}

/// An empty placeholder target plus a root-level Slew that inherits its
/// pointing from the first target in the sequence — the same resolution the
/// Slew editor shows the operator.
Sequence _sequenceWithDetachedSlew() {
  final slew = SlewNode(id: 'slew', parentId: 'root', useTargetCoords: true);
  final target = TargetHeaderNode(
    id: 'target',
    parentId: 'root',
    orderIndex: 1,
    targetName: 'M31',
    raHours: 0,
    decDegrees: 0,
  );
  final root = InstructionSetNode(
    id: 'root',
    name: 'Sequence',
    childIds: const ['slew', 'target'],
  );
  return Sequence.create(
    name: 'detached slew',
    nodes: {root.id: root, slew.id: slew, target.id: target},
    rootNodeId: root.id,
  );
}

List<String?> _codesOf(SequenceValidationException e) =>
    e.errors.map((i) => i.code).toList();

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  ProviderContainer? container;

  ProviderContainer buildContainer() {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(
          () => _FixedSettingsNotifier(const AppSettingsState()),
        ),
        sequenceValidatorProvider.overrideWith(_registryValidator),
      ],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    backend = _PermissiveBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    when(() => backend.sequencerStop()).thenAnswer((_) async {
      scheduleMicrotask(() {
        if (!eventController.isClosed) {
          eventController.add(
            bridge_event.SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: bridge_event.EventSeverity.info,
              category: bridge_event.EventCategory.sequencer,
              eventType: 'Stopped',
              data: const {},
            ),
          );
        }
      });
    });
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    container?.dispose();
    if (!eventController.isClosed) {
      await eventController.close();
    }
    await db.close();
  });

  test(
    'start() refuses a named target still on the 0h/+0 placeholder',
    () async {
      final c = buildContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_sequenceWithTarget(raHours: 0, decDegrees: 0));
      final executor = c.read(sequenceExecutorProvider);

      final error = await executor
          .start()
          .then<Object?>((_) => null)
          .onError((Object e, _) => e);

      expect(
        error,
        isA<SequenceValidationException>(),
        reason:
            'a target whose coordinates were never set must not reach the mount',
      );
      expect(
        _codesOf(error as SequenceValidationException),
        contains('target_coordinates_unset'),
      );
      verifyNever(() => backend.sequencerStart());
    },
  );

  test('start() proceeds once the target carries real coordinates', () async {
    final c = buildContainer();
    c
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWithTarget(raHours: 0.712306, decDegrees: 41.269065),
        );
    final executor = c.read(sequenceExecutorProvider);

    await executor.start();

    verify(() => backend.sequencerStart()).called(1);

    await executor.stop();
  });

  test(
    'a detached Slew inheriting the placeholder also blocks start()',
    () async {
      final c = buildContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_sequenceWithDetachedSlew());
      final executor = c.read(sequenceExecutorProvider);

      final error = await executor
          .start()
          .then<Object?>((_) => null)
          .onError((Object e, _) => e);

      expect(error, isA<SequenceValidationException>());
      expect(
        _codesOf(error as SequenceValidationException),
        contains('target_coordinates_unset'),
        reason:
            'the Slew resolves its pointing to the first target in the sequence, '
            'so an empty placeholder target still aims the mount',
      );
      verifyNever(() => backend.sequencerStart());
    },
  );

  test(
    'the placeholder warns, but does not block, while nothing under it runs',
    () async {
      final c = buildContainer();
      final sequence = _sequenceWithTarget(
        raHours: 0,
        decDegrees: 0,
        childrenEnabled: false,
      );
      c.read(currentSequenceProvider.notifier).loadSequence(sequence);
      final executor = c.read(sequenceExecutorProvider);

      final result = await executor.validateSequenceForStart(sequence);
      final flagged = result.issues
          .where((i) => i.code == 'target_coordinates_unset')
          .toList();

      expect(flagged, hasLength(1));
      expect(flagged.single.severity, ValidationSeverity.warning);
      expect(flagged.single.affectedNodeId, 'target');
      expect(
        result.isValid,
        isTrue,
        reason:
            'blocking an unrelated run on a half-built target teaches the '
            'operator to click through the pre-flight dialog',
      );

      await executor.start();
      verify(() => backend.sequencerStart()).called(1);
      await executor.stop();
    },
  );
}
