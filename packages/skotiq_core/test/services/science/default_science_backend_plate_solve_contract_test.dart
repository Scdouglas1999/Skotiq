import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show FrameCard, FrameHeaderRead, RustLib, RustLibApi;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import '../../harness/in_memory_database.dart';

class _Backend extends Mock implements SkotiqBackend {
  @override
  Stream<SkotiqEvent> get eventStream => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  void dispose() {}
}

class _Native extends Mock implements RustLibApi {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(plateSolveTimeout: 123);
}

class _BlindSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(plateSolveTimeout: 123, blindSolve: true);
}

PlateSolveResult _result({double fieldWidth = 2, double fieldHeight = 1.5}) =>
    PlateSolveResult(
      success: true,
      ra: 157.5,
      dec: 42,
      pixelScale: 1.2,
      rotation: 10,
      fieldWidth: fieldWidth,
      fieldHeight: fieldHeight,
      solveTimeSecs: 0.5,
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
  // The native frame reader: every frame here is 4656 x 3520.
  final native = _Native();
  setUpAll(() {
    when(
      () => native.crateApiFrameFileApiReadFrameHeader(
        filePath: any(named: 'filePath'),
      ),
    ).thenAnswer(
      (_) async => const FrameHeaderRead(
        cards: [
          FrameCard(keyword: 'NAXIS1', text: '4656', number: 4656),
          FrameCard(keyword: 'NAXIS2', text: '3520', number: 3520),
        ],
      ),
    );
    RustLib.initMock(api: native);
  });
  tearDownAll(RustLib.dispose);

  test(
    'science solve converts RA units and forwards configured timeout',
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
      ).thenAnswer((_) async => _result());
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
          appSettingsProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      final wcs = await container
          .read(scienceBackendProvider)
          .solveForScience(
            '/tmp/science.fits',
            const SolveOptions(
              raHintHours: 10.5,
              decHintDegrees: 42,
              searchRadiusDegrees: 2,
            ),
          );

      expect(wcs, isNotNull);
      expect(wcs!.raHours, 10.5);
      verify(
        () => backend.plateSolve(
          imagePath: '/tmp/science.fits',
          ra: 157.5,
          dec: 42,
          fovDegrees: 2,
          timeoutSeconds: 123,
        ),
      ).called(1);
    },
  );

  test('science solve honors forced blind mode', () async {
    final backend = _Backend();
    when(
      () => backend.plateSolve(
        imagePath: any(named: 'imagePath'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        fovDegrees: any(named: 'fovDegrees'),
        timeoutSeconds: any(named: 'timeoutSeconds'),
      ),
    ).thenAnswer((_) async => _result());
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        appSettingsProvider.overrideWith(_BlindSettings.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    await container
        .read(scienceBackendProvider)
        .solveForScience(
          '/tmp/science-blind.fits',
          const SolveOptions(raHintHours: 10.5, decHintDegrees: 42),
        );

    verify(
      () => backend.plateSolve(
        imagePath: '/tmp/science-blind.fits',
        ra: null,
        dec: null,
        fovDegrees: null,
        timeoutSeconds: 123,
      ),
    ).called(1);
  });

  test(
    'a solve whose .wcs names no size takes the field from the frame',
    () async {
      // ASTAP writes NAXIS = 0 into its .wcs, so the native result carries a
      // zero field; the frame header still says 4656 x 3520.
      const framePath = '/frames/frame.fits';

      final backend = _Backend();
      when(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenAnswer((_) async => _result(fieldWidth: 0, fieldHeight: 0));
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
          appSettingsProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      final wcs = await container
          .read(scienceBackendProvider)
          .solveForScience(framePath, const SolveOptions());

      expect(wcs!.fieldWidthDegrees, closeTo(4656 * 1.2 / 3600, 1e-9));
      expect(wcs.fieldHeightDegrees, closeTo(3520 * 1.2 / 3600, 1e-9));
    },
  );
}
