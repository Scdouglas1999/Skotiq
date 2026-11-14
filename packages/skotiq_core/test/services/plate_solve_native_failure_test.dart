// A native solve that throws is the answer the user sees: no second solver
// runs in Dart. That one read CRVAL as the field center (the 792" offset of an
// astrometry.net solution without --crpix-center) and dropped the rotation of
// a CD-matrix .wcs.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
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

void main() {
  test('a native solve that throws reports its error and starts no solver '
      'of its own', () async {
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
    ).thenThrow(StateError('Plate solve did not return within 75 seconds'));
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      ],
    );
    addTearDown(container.dispose);

    final temp = await Directory.systemTemp.createTemp('skotiq-solve-');
    addTearDown(() => temp.delete(recursive: true));
    final imagePath = '${temp.path}/frame.fits';
    final ranPath = '${temp.path}/solver-ran';
    await File(imagePath).writeAsString('fixture');
    // An ASTAP stand-in that writes a rotated CD-matrix solution whose
    // reference pixel is far from the frame center.
    final script = File('${temp.path}/fake-astap.sh');
    await script.writeAsString(
      '#!/bin/sh\n'
      "touch '$ranPath'\n"
      "printf 'CRVAL1  =                 10.0\\nCRVAL2  =                 41.0\\n"
      "CRPIX1  =                100.0\\nCRPIX2  =                100.0\\n"
      "CD1_1   =           -0.0002000\\nCD1_2   =            0.0002000\\n"
      "CD2_1   =            0.0002000\\nCD2_2   =            0.0002000\\n"
      "END\\n' > '${temp.path}/frame.wcs'\n",
    );
    expect((await Process.run('chmod', ['+x', script.path])).exitCode, 0);

    when(() => backend.detectPlateSolvers()).thenAnswer(
      (_) async =>
          PlateSolverDetection(astapPath: script.path, catalogPath: temp.path),
    );
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.astap),
    );

    final result = await container
        .read(plateSolveServiceProvider)
        .solveWithFallback(imagePath: imagePath);

    expect(result.success, isFalse);
    expect(result.error, contains('did not return within 75 seconds'));
    expect(File(ranPath).existsSync(), isFalse);
  });
}
