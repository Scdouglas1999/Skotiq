// Startup discovery must query the Alpaca server the operator configured.
//
// Settings → Connection carries "Query Alpaca on startup / Include the
// configured Alpaca server in automatic startup discovery". The address editor
// behind that promise is covered by
// skotiq_app/test/screens/settings/connection_alpaca_address_test.dart —
// but a stored address nothing reads is the same defect wearing a UI. These
// tests hold the other end: that `discoverAll` sends the *stored* host and port
// to the backend, so an ASCOM Remote host on the LAN is actually reachable
// rather than everyone being pinned to localhost:11111 forever.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockDeviceService extends Mock implements DeviceService {}

class _SettingsNotifier extends AppSettingsNotifier {
  _SettingsNotifier(this._state);

  final AppSettingsState _state;

  @override
  Future<AppSettingsState> build() async => _state;
}

void main() {
  setUpAll(() {
    registerFallbackValue(DeviceType.camera);
  });

  ProviderContainer createContainer(
    AppSettingsState settings,
    DeviceService s,
  ) {
    return ProviderContainer(
      overrides: [
        deviceServiceProvider.overrideWithValue(s),
        appSettingsProvider.overrideWith(() => _SettingsNotifier(settings)),
      ],
    );
  }

  DeviceService stubService() {
    final service = _MockDeviceService();
    when(
      () => service.discoverDevices(any()),
    ).thenAnswer((_) async => const []);
    when(
      () => service.discoverIndiAtAddress(any(), any()),
    ).thenAnswer((_) async => const []);
    when(
      () => service.discoverAlpacaAtAddress(any(), any()),
    ).thenAnswer((_) async => const []);
    return service;
  }

  test('startup discovery queries the configured Alpaca host and port', () async {
    final service = stubService();
    final container = createContainer(
      const AppSettingsState(
        alpacaServerHost: '192.168.1.47',
        alpacaServerPort: 32323,
      ),
      service,
    );
    addTearDown(container.dispose);
    // Guard the remote-mode short circuit: in remote mode every driver collapses
    // into one network bucket and no per-protocol address is used at all.
    expect(container.read(isRemoteModeProvider), isFalse);

    await container
        .read(unifiedDiscoveryProvider.notifier)
        .discoverAll(includeIndi: false);

    verify(
      () => service.discoverAlpacaAtAddress('192.168.1.47', 32323),
    ).called(1);
    verifyNever(() => service.discoverAlpacaAtAddress('localhost', 11111));
  });

  test('the stored Alpaca address is not confused with the INDI one', () async {
    final service = stubService();
    final container = createContainer(
      const AppSettingsState(
        alpacaServerHost: 'alpaca-host',
        alpacaServerPort: 11111,
        indiServerHost: 'indi-host',
        indiServerPort: 7624,
      ),
      service,
    );
    addTearDown(container.dispose);

    await container.read(unifiedDiscoveryProvider.notifier).discoverAll();

    verify(
      () => service.discoverAlpacaAtAddress('alpaca-host', 11111),
    ).called(1);
    verify(() => service.discoverIndiAtAddress('indi-host', 7624)).called(1);
  });

  test('Alpaca is not queried at all when the startup toggle is off', () async {
    final service = stubService();
    final container = createContainer(
      const AppSettingsState(alpacaServerHost: '10.0.0.5'),
      service,
    );
    addTearDown(container.dispose);

    await container
        .read(unifiedDiscoveryProvider.notifier)
        .discoverAll(includeAlpaca: false);

    verifyNever(() => service.discoverAlpacaAtAddress(any(), any()));
  });
}
