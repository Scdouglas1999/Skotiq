import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/backend/network_backend/host_data/remote_science_products.dart';

class _CountingBackend extends NetworkBackend {
  _CountingBackend()
    : super(
        serverHost: '127.0.0.1',
        serverPort: 9,
        autoConnectWebSocket: false,
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      );

  var disposeCallbacks = 0;

  @override
  void registerOnDispose(void Function() callback) {
    disposeCallbacks++;
    super.registerOnDispose(callback);
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }
}

void main() {
  test('scienceProducts does not register a host dispose callback', () {
    final backend = _CountingBackend();
    addTearDown(backend.dispose);
    final before = backend.disposeCallbacks;

    final products = backend.remoteHost!.scienceProducts();

    expect(backend.disposeCallbacks, before);
    expect(products.isDisposedForTest, isFalse);
    products.dispose();
    expect(products.isDisposedForTest, isTrue);
  });

  test('the science products provider disposes its poll with the provider', () {
    final backend = _CountingBackend();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        remoteSciencePollIntervalProvider.overrideWithValue(
          const Duration(hours: 1),
        ),
      ],
    );
    final products =
        container.read(scienceProductsProvider) as RemoteScienceProducts;

    expect(products.isDisposedForTest, isFalse);
    expect(backend.disposeCallbacks, 0);

    container.dispose();

    expect(products.isDisposedForTest, isTrue);
    expect(backend.disposeCallbacks, 0);
    backend.dispose();
  });
}
