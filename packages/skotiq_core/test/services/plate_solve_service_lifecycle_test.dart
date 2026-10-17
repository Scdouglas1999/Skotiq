import 'dart:async';
import 'dart:io';
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

class _RemoteBackend extends Mock implements NetworkBackend {
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

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

class _BlindSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(blindSolve: true);
}

PlateSolveResult _solveResult({bool success = true, String? error}) {
  return PlateSolveResult(
    success: success,
    ra: success ? 150 : 0,
    dec: success ? 45 : 0,
    rotation: 0,
    pixelScale: success ? 1 : 0,
    fieldWidth: success ? 2 : 0,
    fieldHeight: success ? 1.5 : 0,
    solveTimeSecs: 0,
    error: error,
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
}

ProviderContainer _containerFor(SkotiqBackend backend) {
  return ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
    ],
  );
}

void main() {
  const config = PlateSolverConfig(
    type: PlateSolverType.astap,
    executablePath: '/opt/astap/astap',
  );

  test(
    'concurrent solves are rejected without starting a second backend run',
    () async {
      final backend = _Backend();
      final completer = Completer<PlateSolveResult>();
      when(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenAnswer((_) => completer.future);
      final container = _containerFor(backend);
      addTearDown(container.dispose);
      final service = container.read(plateSolveServiceProvider);

      final first = service.solve('/tmp/first.fits', config);
      await untilCalled(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      );
      final second = await service.solve('/tmp/second.fits', config);

      expect(second.success, isFalse);
      expect(second.error, contains('already running'));
      expect(container.read(plateSolveStateProvider).isSolving, isTrue);
      verify(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).called(1);

      completer.complete(_solveResult());
      expect((await first).success, isTrue);
      expect(container.read(plateSolveStateProvider).isSolving, isFalse);
    },
  );

  test(
    'old-host solve completion cannot publish into the replacement host',
    () async {
      final backendA = _Backend();
      final backendB = _Backend();
      final result = Completer<PlateSolveResult>();
      when(
        () => backendA.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenAnswer((_) => result.future);
      late _BackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => backendNotifier = _BackendNotifier(ref, backendA),
          ),
        ],
      );
      addTearDown(container.dispose);

      final serviceA = container.read(plateSolveServiceProvider);
      final solve = serviceA.solve('/tmp/old-host.fits', config);
      await untilCalled(
        () => backendA.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      );
      expect(container.read(plateSolveStateProvider).isSolving, isTrue);

      final queuedAnnotation = serviceA.solveForAnnotation(
        imagePath: '/tmp/annotation-old-host.fits',
        isCurrent: () => true,
      );
      backendNotifier.replaceBackend(backendB);
      final serviceB = container.read(plateSolveServiceProvider);
      expect(serviceB, isNot(same(serviceA)));
      expect(container.read(plateSolveStateProvider).isSolving, isFalse);

      result.complete(_solveResult());
      expect((await solve).success, isTrue);
      expect(await queuedAnnotation, isNull);
      expect(container.read(plateSolveStateProvider).lastResult, isNull);
    },
  );

  test(
    'service converts RA hint and forwards timeout at backend boundary',
    () async {
      final backend = _Backend();
      when(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenAnswer((_) async => _solveResult());
      final container = _containerFor(backend);
      addTearDown(container.dispose);

      await container
          .read(plateSolveServiceProvider)
          .solve(
            '/tmp/hinted.fits',
            const PlateSolverConfig(
              type: PlateSolverType.astap,
              executablePath: '/opt/astap/astap',
              hintRa: 10.5,
              hintDec: 42,
              timeoutSeconds: 47,
            ),
          );

      verify(
        () => backend.plateSolve(
          imagePath: '/tmp/hinted.fits',
          ra: 157.5,
          dec: 42,
          fovDegrees: null,
          timeoutSeconds: 47,
        ),
      ).called(1);
    },
  );

  test('a thrown setup error always clears the solving state', () async {
    final backend = _Backend();
    when(
      () => backend.detectPlateSolvers(),
    ).thenThrow(StateError('probe failed'));
    final container = _containerFor(backend);
    addTearDown(container.dispose);
    final service = container.read(plateSolveServiceProvider);

    await expectLater(
      service.solveWithFallback(imagePath: '/tmp/probe.fits'),
      throwsA(isA<StateError>()),
    );

    expect(container.read(plateSolveStateProvider).isSolving, isFalse);
  });

  test('Blind solve setting strips otherwise valid position hints', () async {
    final backend = _RemoteBackend();
    when(() => backend.detectPlateSolvers()).thenAnswer(
      (_) async => const PlateSolverDetection(
        astapPath: '/opt/astap/astap',
        catalogPath: '/opt/astap',
      ),
    );
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.astap),
    );
    when(
      () => backend.plateSolve(
        imagePath: any(named: 'imagePath'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        fovDegrees: any(named: 'fovDegrees'),
        timeoutSeconds: any(named: 'timeoutSeconds'),
      ),
    ).thenAnswer((_) async => _solveResult());
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        appSettingsProvider.overrideWith(_BlindSettings.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final result = await container
        .read(plateSolveServiceProvider)
        .solveWithFallback(
          imagePath: '/tmp/blind.fits',
          hintRaHours: 10.5,
          hintDecDegrees: 42,
        );

    expect(result.success, isTrue);
    verify(
      () => backend.plateSolve(
        imagePath: '/tmp/blind.fits',
        ra: null,
        dec: null,
        fovDegrees: 30,
        timeoutSeconds: 60,
      ),
    ).called(1);
  });

  test(
    'remote backend failure does not run a host path on the client',
    () async {
      final backend = _RemoteBackend();
      when(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenThrow(StateError('host disconnected'));
      final container = _containerFor(backend);
      addTearDown(container.dispose);

      final result = await container
          .read(plateSolveServiceProvider)
          .solve('/host-only/frame.fits', config);

      expect(result.success, isFalse);
      expect(result.error, contains('Remote host plate solve failed'));
      expect(result.error, contains('host disconnected'));
      expect(result.error, isNot(contains('Local fallback')));
    },
  );

  test('ASTAP local fallback passes its RA hint in hours', () async {
    if (Platform.isWindows) return;
    final backend = _Backend();
    when(
      () => backend.plateSolve(
        imagePath: any(named: 'imagePath'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        fovDegrees: any(named: 'fovDegrees'),
        timeoutSeconds: any(named: 'timeoutSeconds'),
      ),
    ).thenThrow(StateError('native backend unavailable'));
    final container = _containerFor(backend);
    addTearDown(container.dispose);
    final temp = await Directory.systemTemp.createTemp('skotiq-astap-ra-');
    addTearDown(() => temp.delete(recursive: true));
    final imagePath = '${temp.path}/frame.fits';
    final argsPath = '${temp.path}/args.txt';
    final script = File('${temp.path}/fake-astap.sh');
    await File(imagePath).writeAsString('fixture');
    await script.writeAsString(
      '#!/bin/sh\n'
      "printf '%s\\n' \"\$@\" > '$argsPath'\n"
      'exit 1\n',
    );
    expect((await Process.run('chmod', ['+x', script.path])).exitCode, 0);

    await container
        .read(plateSolveServiceProvider)
        .solve(
          imagePath,
          PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: script.path,
            hintRa: 10.5,
            hintDec: 42,
          ),
        );

    final args = await File(argsPath).readAsLines();
    final raIndex = args.indexOf('-ra');
    expect(raIndex, greaterThanOrEqualTo(0));
    expect(args[raIndex + 1], '10.5');
    expect(args, contains('132.0'));
  });

  test(
    'local solver timeout terminates the process before returning',
    () async {
      if (Platform.isWindows) return;
      final backend = _Backend();
      when(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenThrow(StateError('native backend unavailable'));
      final container = _containerFor(backend);
      addTearDown(container.dispose);
      final temp = await Directory.systemTemp.createTemp('skotiq-timeout-');
      addTearDown(() => temp.delete(recursive: true));
      final imagePath = '${temp.path}/frame.fits';
      final markerPath = '${temp.path}/solver-finished';
      final script = File('${temp.path}/fake-astap.sh');
      await File(imagePath).writeAsString('fixture');
      await script.writeAsString(
        '#!/bin/sh\n'
        'sleep 2\n'
        "printf stale > '$markerPath'\n",
      );
      final chmod = await Process.run('chmod', ['+x', script.path]);
      expect(chmod.exitCode, 0);

      final result = await container
          .read(plateSolveServiceProvider)
          .solve(
            imagePath,
            PlateSolverConfig(
              type: PlateSolverType.astap,
              executablePath: script.path,
              timeoutSeconds: 1,
            ),
          );

      expect(result.success, isFalse);
      expect(result.error, contains('timed out'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(
        await File(markerPath).exists(),
        isFalse,
        reason: 'A timed-out solver must not keep running in the background',
      );
    },
  );
}
