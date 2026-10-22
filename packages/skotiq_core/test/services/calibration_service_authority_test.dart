import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _ReplaceableBackendNotifier extends BackendNotifier {
  _ReplaceableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void replaceWith(SkotiqBackend next) => state = next;
}

void main() {
  test(
    'a host switch after dark matching prevents calibration on either rig',
    () async {
      final oldBackend = _MockNetworkBackend();
      final newBackend = _MockNetworkBackend();
      final match = Completer<String?>();
      when(
        () => oldBackend.matchDarkFromLibrary(
          exposureTime: any(named: 'exposureTime'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
          temperature: any(named: 'temperature'),
        ),
      ).thenAnswer((_) => match.future);

      late _ReplaceableBackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) {
            backendNotifier = _ReplaceableBackendNotifier(ref, oldBackend);
            return backendNotifier;
          }),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(calibrationServiceProvider);

      final calibration = service.calibrateFile(
        lightPath: '/host/light.fits',
        settings: const CalibrationSettings(),
        exposureTime: 120,
        gain: 100,
      );
      await Future<void>.delayed(Duration.zero);
      backendNotifier.replaceWith(newBackend);
      match.complete('/host/master-dark.fits');

      await expectLater(
        calibration,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('host changed'),
          ),
        ),
      );
      verifyNever(
        () => oldBackend.calibrateImageFile(
          lightPath: any(named: 'lightPath'),
          darkPath: any(named: 'darkPath'),
          flatPath: any(named: 'flatPath'),
          biasPath: any(named: 'biasPath'),
          outputPath: any(named: 'outputPath'),
        ),
      );
      verifyNever(
        () => newBackend.calibrateImageFile(
          lightPath: any(named: 'lightPath'),
          darkPath: any(named: 'darkPath'),
          flatPath: any(named: 'flatPath'),
          biasPath: any(named: 'biasPath'),
          outputPath: any(named: 'outputPath'),
        ),
      );
    },
  );

  test(
    'a Windows host frame gets its _cal sibling in the host path style',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.matchDarkFromLibrary(
          exposureTime: any(named: 'exposureTime'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
          temperature: any(named: 'temperature'),
        ),
      ).thenAnswer((_) async => r'C:\Users\scdou\Documents\Darks\master.fits');
      when(
        () => backend.calibrateImageFile(
          lightPath: any(named: 'lightPath'),
          darkPath: any(named: 'darkPath'),
          flatPath: any(named: 'flatPath'),
          biasPath: any(named: 'biasPath'),
          outputPath: any(named: 'outputPath'),
        ),
      ).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _ReplaceableBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);

      const light = r'C:\Users\scdou\Documents\NGC7380\NGC0891_L_0001.fits';
      final result = await container
          .read(calibrationServiceProvider)
          .calibrateFile(
            lightPath: light,
            settings: const CalibrationSettings(),
            exposureTime: 120,
            gain: 100,
          );

      const expected =
          r'C:\Users\scdou\Documents\NGC7380\NGC0891_L_0001_cal.fits';
      expect(result.outputPath, expected);
      verify(
        () => backend.calibrateImageFile(
          lightPath: light,
          darkPath: any(named: 'darkPath'),
          flatPath: any(named: 'flatPath'),
          biasPath: any(named: 'biasPath'),
          outputPath: expected,
        ),
      ).called(1);
    },
  );
}
