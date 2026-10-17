// A "successful" solve with no usable geometry is not a solution.
//
// Checking only the success flag lets the Annotate chip go "Searching
// catalogs…" → "Found 0 objects" in the green success treatment on a frame the
// solver did not solve — no .wcs on disk, the viewport's own sky readout still
// "Sky --". "Found 0 objects" is a statement about the sky; a user who trusts it
// concludes their field is empty rather than that solving is broken. A result
// carrying no field scale becomes a catalog search over a field of zero size,
// which returns nothing.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:path/path.dart' as path;

import '../harness/in_memory_database.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _Settings extends AnnotationSettingsNotifier {
  @override
  Future<AnnotationSettings> build() async => const AnnotationSettings();
}

PlateSolveResult _result({
  required double pixelScale,
  required double fieldWidth,
  double ra = 10,
  double dec = 20,
}) => PlateSolveResult(
  success: true,
  ra: ra,
  dec: dec,
  pixelScale: pixelScale,
  rotation: 0,
  fieldWidth: fieldWidth,
  fieldHeight: fieldWidth,
  solveTimeSecs: 0.1,
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
  setUpAll(() {
    registerFallbackValue('');
    registerFallbackValue(0.0);
  });

  Future<AnnotationState> runPipeline(PlateSolveResult solve) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'annotation_geometry_test_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));

    await CatalogManager.instance.initialize(tempDir.path);
    await File(CatalogManager.instance.annotationCatalogPath).writeAsString(
      'RAJ2000,DEJ2000,Bmag,zhelio,PGC\n'
      // Deliberately OFF the solved centre (by 0.01°, ~24 px at 1.5"/px):
      // an object sitting exactly on the centre is inside even a zero-radius
      // cone, so a fixture at (10, 20) cannot tell a real field from a field
      // of zero size — which is the whole question here.
      '10.0,20.01,12.3,7000,12345\n',
    );

    final backend = _MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.plateSolve(
        imagePath: any(named: 'imagePath'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        fovDegrees: any(named: 'fovDegrees'),
        timeoutSeconds: any(named: 'timeoutSeconds'),
      ),
    ).thenAnswer((_) async => solve);
    // The annotate pipeline solves through PlateSolveService (the same entry
    // every other feature uses), so the solver-choice probe has to answer.
    when(() => backend.detectPlateSolvers()).thenAnswer(
      (_) async => const PlateSolverDetection(
        astapPath: '/usr/bin/astap',
        catalogPath: '/usr/share/astap',
      ),
    );
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.astap),
    );

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        annotationSettingsProvider.overrideWith(_Settings.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(annotationServiceProvider);

    final imagePath = path.join(tempDir.path, 'frame.fits');
    await File(imagePath).writeAsString('test');

    final terminal = Completer<AnnotationState>();
    container.listen(annotationStateProvider, (previous, next) {
      if (!next.isProcessing &&
          next.status != AnnotationStatus.idle &&
          !terminal.isCompleted) {
        terminal.complete(next);
      }
    });

    container.read(currentImageProvider.notifier).state = CapturedImageData(
      width: 100,
      height: 100,
      displayData: Uint8List(100 * 100 * 4),
      histogram: List.filled(256, 0),
      stats: const ImageStats(mean: 0),
      capturedAt: DateTime.now(),
      settings: const ExposureSettings(exposureTime: 1, gain: 100, offset: 10),
      filePath: imagePath,
    );

    return terminal.future.timeout(const Duration(seconds: 5));
  }

  test('a solve with no field scale is reported as a failed solve', () async {
    final state = await runPipeline(_result(pixelScale: 0, fieldWidth: 0));

    expect(
      state.status,
      AnnotationStatus.plateSolveFailed,
      reason: 'no scale means no field to search, so "0 objects" is not a fact',
    );
    expect(state.objectsFound, isNot(0));
  });

  test('a solve with real geometry still annotates', () async {
    final state = await runPipeline(_result(pixelScale: 1.5, fieldWidth: 1));

    expect(state.status, AnnotationStatus.complete);
    expect(state.objectsFound, greaterThan(0));
  });

  // The FIELD SIZE is the other half, separate from the centre and the scale:
  // the local ASTAP/astrometry parsers recover position and scale only and leave
  // the field at zero, and the catalog search radius is derived from the field,
  // so a solve with a perfectly good centre searches a cone of radius ZERO and
  // returns nothing. "Found 0 objects" then describes the operator's sky rather
  // than the app's arithmetic.
  test(
    'a solve with a scale but no field size still finds its objects',
    () async {
      final state = await runPipeline(_result(pixelScale: 1.5, fieldWidth: 0));

      expect(
        state.status,
        AnnotationStatus.complete,
        reason: 'the field is recoverable from the scale and the frame size',
      );
      expect(
        state.objectsFound,
        greaterThan(0),
        reason:
            'a zero-radius catalog query is what produced "Found 0 objects"',
      );
    },
  );

  test(
    'a solve with neither field size nor scale is reported as failed',
    () async {
      final state = await runPipeline(_result(pixelScale: 0, fieldWidth: 0));

      expect(state.status, AnnotationStatus.plateSolveFailed);
    },
  );
}
