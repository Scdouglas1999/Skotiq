import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _Phd2PathSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    return const AppSettingsState(
      phd2Path: r'C:\Program Files\PHD2\phd2.exe',
      phd2Host: 'localhost',
      phd2Port: 4400,
    );
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
    registerFallbackValue(DeviceType.guider);
  });

  group('pollPhd2Connected', () {
    test('retries after transient status errors', () {
      fakeAsync((async) {
        final backend = _MockNetworkBackend();
        var calls = 0;
        when(() => backend.phd2GetStatus()).thenAnswer((_) async {
          calls++;
          if (calls < 3) {
            throw StateError('PHD2 client not ready');
          }
          return const Phd2Status(
            state: 'Stopped',
            connected: true,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          );
        });

        Phd2Status? result;
        pollPhd2Connected(
          backend,
          timeout: const Duration(seconds: 2),
          interval: const Duration(milliseconds: 100),
        ).then((status) => result = status);

        async.elapse(const Duration(milliseconds: 500));
        expect(result, isNotNull);
        expect(result!.connected, isTrue);
        expect(calls, 3);
      });
    });
  });

  group('Phd2Controller remote connect', () {
    test(
      'calls host PHD2 API even when settings include a desktop path',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => backend.phd2Connect(
            host: any(named: 'host'),
            port: any(named: 'port'),
          ),
        ).thenAnswer((_) async {});
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Stopped',
            connected: true,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            appSettingsProvider.overrideWith(_Phd2PathSettingsNotifier.new),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        await container.read(phd2ControllerProvider).connect('localhost', 4400);

        verify(
          () => backend.phd2Connect(host: 'localhost', port: 4400),
        ).called(1);
        verify(() => backend.phd2GetStatus()).called(1);
        expect(
          container.read(guiderStateProvider).connectionState,
          DeviceConnectionState.connected,
        );
      },
    );

    test(
      'pollPhd2Connected throws when host never reports connected',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.phd2GetStatus(),
        ).thenAnswer((_) async => kPhd2DisconnectedStatus);

        await expectLater(
          pollPhd2Connected(
            backend,
            timeout: const Duration(milliseconds: 200),
            interval: const Duration(milliseconds: 50),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('DeviceService PHD2 connect', () {
    test(
      'connectGuider waits for host PHD2 status on NetworkBackend',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => backend.phd2Connect(
            host: any(named: 'host'),
            port: any(named: 'port'),
          ),
        ).thenAnswer((_) async {});
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Stopped',
            connected: true,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            appSettingsProvider.overrideWith(_Phd2PathSettingsNotifier.new),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(deviceServiceProvider)
            .connectGuider('phd2_guider');

        verify(
          () => backend.phd2Connect(host: '127.0.0.1', port: 4400),
        ).called(1);
        verify(() => backend.phd2GetStatus()).called(1);
        expect(
          container.read(guiderStateProvider).connectionState,
          DeviceConnectionState.connected,
        );
      },
    );
  });

  group('remote session PHD2 hydration', () {
    test(
      'does not clear guider when status poll fails after device list hydrate',
      () async {
        final backend = _MockNetworkBackend();
        when(() => backend.sequencerGetStatus()).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(() => backend.getConnectedDevices()).thenAnswer(
          (_) async => const [
            DeviceInfo(
              id: 'phd2_guider',
              name: 'PHD2',
              deviceType: DeviceType.guider,
              driverType: DriverType.native,
              description: '',
              driverVersion: '1.0',
            ),
          ],
        );
        when(
          () => backend.phd2GetStatus(),
        ).thenThrow(StateError('PHD2 not connected'));

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        await hydrateRemoteSessionState(container, backend);

        expect(
          container.read(guiderStateProvider).connectionState,
          DeviceConnectionState.connected,
        );
        expect(container.read(guiderStateProvider).deviceId, 'phd2_guider');
      },
    );
  });
}
