// A background solve of the frame on screen must never turn an operator's
// solve away, and must not show as the operator's solve.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _Backend extends Mock implements SkotiqBackend {
  @override
  Stream<SkotiqEvent> get eventStream => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  void dispose() {}
}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

PlateSolveResult _result(double ra) => PlateSolveResult(
  success: true,
  ra: ra,
  dec: 45,
  rotation: 0,
  pixelScale: 1,
  fieldWidth: 2,
  fieldHeight: 1.5,
  solveTimeSecs: 0,
  cd11: 0,
  cd12: 0,
  cd21: 0,
  cd22: 0,
  sipAOrder: 0,
  sipBOrder: 0,
  sipACoeffs: Float64List(0),
  sipBCoeffs: Float64List(0),
  sipApOrder: 0,
  sipBpOrder: 0,
  sipApCoeffs: Float64List(0),
  sipBpCoeffs: Float64List(0),
);

void main() {
  late _Backend backend;
  late ProviderContainer container;
  final solves = <String, Completer<PlateSolveResult>>{};

  Future<PlateSolveResult> Function(Invocation) answer() => (inv) {
    final path = inv.namedArguments[#imagePath] as String;
    return (solves[path] = Completer<PlateSolveResult>()).future;
  };

  void whenSolve() => when(
    () => backend.plateSolve(
      imagePath: any(named: 'imagePath'),
      ra: any(named: 'ra'),
      dec: any(named: 'dec'),
      fovDegrees: any(named: 'fovDegrees'),
      timeoutSeconds: any(named: 'timeoutSeconds'),
    ),
  ).thenAnswer(answer());

  setUp(() {
    solves.clear();
    backend = _Backend();
    when(() => backend.detectPlateSolvers()).thenAnswer(
      (_) async => const PlateSolverDetection(
        astapPath: '/opt/astap/astap_cli',
        catalogPath: '/opt/astap',
      ),
    );
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.astap),
    );
    whenSolve();
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'an operator solve waits for a background solve instead of failing',
    () async {
      final service = container.read(plateSolveServiceProvider);
      final background = service.solveInBackground(
        imagePath: '/frames/a.fits',
        isCurrent: () => true,
      );
      for (var i = 0; i < 5 && !solves.containsKey('/frames/a.fits'); i++) {
        await settle();
      }
      expect(solves.keys, ['/frames/a.fits']);
      // The background solve is not the operator's: nothing says "solving".
      expect(container.read(plateSolveStateProvider).isSolving, isFalse);

      final operator = service.solveWithFallback(imagePath: '/frames/b.fits');
      await settle();
      expect(solves.keys, ['/frames/a.fits'], reason: 'it waits its turn');

      solves['/frames/a.fits']!.complete(_result(10));
      expect((await background)!.ra, 10);
      for (var i = 0; i < 5 && !solves.containsKey('/frames/b.fits'); i++) {
        await settle();
      }
      solves['/frames/b.fits']!.complete(_result(20));
      final result = await operator;
      expect(result.success, isTrue);
      expect(result.ra, 20);
      expect(container.read(plateSolveStateProvider).lastResult?.ra, 20);
    },
  );

  test('a background solve of a replaced frame never starts', () async {
    final service = container.read(plateSolveServiceProvider);
    var current = true;
    final operator = service.solveWithFallback(imagePath: '/frames/op.fits');
    for (var i = 0; i < 5 && !solves.containsKey('/frames/op.fits'); i++) {
      await settle();
    }
    final background = service.solveInBackground(
      imagePath: '/frames/old.fits',
      isCurrent: () => current,
    );
    current = false;
    solves['/frames/op.fits']!.complete(_result(1));
    await operator;
    expect(await background, isNull);
    expect(solves.keys, ['/frames/op.fits']);
  });

  test('no solver set up surfaces as SolverNotAvailableError', () async {
    when(
      () => backend.detectPlateSolvers(),
    ).thenAnswer((_) async => const PlateSolverDetection());
    final service = container.read(plateSolveServiceProvider);
    await expectLater(
      service.solveInBackground(
        imagePath: '/frames/a.fits',
        isCurrent: () => true,
      ),
      throwsA(isA<SolverNotAvailableError>()),
    );
  });
}
