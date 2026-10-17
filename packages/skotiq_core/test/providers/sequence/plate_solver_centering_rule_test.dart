// Driving the built bundle on 2026-09-09 with the "Mono LRGB M51" starter:
// pre-flight said "Ready with warnings", Start was enabled, and the run died
// after 0 s because the executor refuses a centring sequence with no plate
// solver. The reason was only readable three levels deep, in History →
// Session summary. Pre-flight has to say it BEFORE the run.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/plate_solver.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/plate_solver_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/plate_solver_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';

final _probeProvider = Provider<Ref>((ref) => ref);

ProviderContainer _containerWith({
  required AsyncValue<PlateSolverDetection> detection,
  PlateSolverChoice choice = PlateSolverChoice.auto,
}) {
  return ProviderContainer(
    overrides: [
      plateSolverDetectionProvider.overrideWith((ref) async {
        return detection.when(
          data: (d) => d,
          loading: () => Completer<PlateSolverDetection>().future,
          error: (e, _) => throw e,
        );
      }),
      plateSolverPreferenceProvider.overrideWith(
        (ref) async => PlateSolverPreference(choice: choice),
      ),
    ],
  );
}

/// A sequence whose only enabled node centres on the target.
Sequence _centringSequence({bool enabled = true}) {
  const rootId = 'root';
  const centerId = 'center';
  return Sequence.create(
    name: 'M51',
    nodes: {
      rootId: InstructionSetNode(id: rootId, name: 'Sequence'),
      centerId: CenterNode(id: centerId, parentId: rootId, isEnabled: enabled),
    },
    rootNodeId: rootId,
  );
}

Sequence _plainSequence() {
  const rootId = 'root';
  return Sequence.create(
    name: 'Darks',
    nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
    rootNodeId: rootId,
  );
}

Future<List<ValidationIssue>> _run(
  ProviderContainer container,
  Sequence sequence,
) async {
  // Let the overridden futures settle so `valueOrNull` is populated.
  await container
      .read(plateSolverDetectionProvider.future)
      .catchError((_) => const PlateSolverDetection());
  await container.read(plateSolverPreferenceProvider.future);
  return PlateSolverForCenteringRule().validate(
    sequence,
    ValidationContext(container.read(_probeProvider)),
  );
}

void main() {
  for (final focal in [0.0, double.nan, double.infinity, 1000.0]) {
    test('centering discloses missing or invalid focal length ($focal)', () {
      final container = ProviderContainer(
        overrides: [
          activeEquipmentProfileProvider.overrideWithValue(
            EquipmentProfileModel(name: 'Imaging', focalLength: focal),
          ),
        ],
      );
      addTearDown(container.dispose);
      final issues = PlateSolveFocalLengthRule().validate(
        _centringSequence(),
        ValidationContext(container.read(_probeProvider)),
      );
      if (focal.isFinite && focal > 0) {
        expect(issues, isEmpty);
      } else {
        expect(issues.single.severity, ValidationSeverity.warning);
      }
      expect(
        PlateSolveFocalLengthRule().validate(
          _centringSequence(enabled: false),
          ValidationContext(container.read(_probeProvider)),
        ),
        isEmpty,
      );
    });
  }

  test(
    'a centring sequence with no solver is an ERROR, not a warning',
    () async {
      final container = _containerWith(
        detection: const AsyncValue.data(PlateSolverDetection()),
      );
      addTearDown(container.dispose);

      final issues = await _run(container, _centringSequence());

      expect(issues, hasLength(1));
      expect(issues.single.severity, ValidationSeverity.error);
      expect(issues.single.title, 'No plate solver');
      expect(issues.single.description, contains('centres on its target'));
      expect(issues.single.resolutionHint, contains('ASTAP'));
    },
  );

  test('an installed, catalogued ASTAP satisfies it', () async {
    final container = _containerWith(
      detection: const AsyncValue.data(
        PlateSolverDetection(
          astapPath: '/usr/bin/astap',
          catalogPath: '/usr/share/astap/d50',
        ),
      ),
    );
    addTearDown(container.dispose);

    expect(await _run(container, _centringSequence()), isEmpty);
  });

  test('ASTAP without a catalog cannot solve, so it still errors', () async {
    final container = _containerWith(
      detection: const AsyncValue.data(
        PlateSolverDetection(astapPath: '/usr/bin/astap'),
      ),
      choice: PlateSolverChoice.astap,
    );
    addTearDown(container.dispose);

    expect(await _run(container, _centringSequence()), hasLength(1));
  });

  test('a sequence that never centres is not blocked', () async {
    final container = _containerWith(
      detection: const AsyncValue.data(PlateSolverDetection()),
    );
    addTearDown(container.dispose);

    expect(await _run(container, _plainSequence()), isEmpty);
  });

  test('a DISABLED center node is not a reason to block', () async {
    final container = _containerWith(
      detection: const AsyncValue.data(PlateSolverDetection()),
    );
    addTearDown(container.dispose);

    expect(await _run(container, _centringSequence(enabled: false)), isEmpty);
  });

  test('an unanswered probe never blocks a run that would have worked', () {
    final container = _containerWith(
      detection: const AsyncValue<PlateSolverDetection>.loading(),
    );
    addTearDown(container.dispose);

    // Deliberately NOT awaited: the detection future is still in flight.
    final issues = PlateSolverForCenteringRule().validate(
      _centringSequence(),
      ValidationContext(container.read(_probeProvider)),
    );
    expect(issues, isEmpty);
  });
}
