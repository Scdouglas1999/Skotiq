import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';

void main() {
  test('an older failed connect cannot disconnect a newer live host', () async {
    final first = _MockNetworkBackend();
    final second = _MockNetworkBackend();
    final firstConnect = Completer<void>();
    final secondConnect = Completer<void>();
    var firstConnected = false;
    var secondConnected = false;

    when(() => first.connect()).thenAnswer((_) => firstConnect.future);
    when(() => second.connect()).thenAnswer((_) => secondConnect.future);
    when(() => first.connectionState).thenAnswer(
      (_) => firstConnected
          ? BackendConnectionState.connected
          : BackendConnectionState.connecting,
    );
    when(() => second.connectionState).thenAnswer(
      (_) => secondConnected
          ? BackendConnectionState.connected
          : BackendConnectionState.connecting,
    );
    when(() => first.isRemoteHost).thenReturn(false);
    when(() => second.isRemoteHost).thenReturn(false);

    final candidates = <NetworkBackend>[first, second];
    NetworkBackend factory({
      required String serverHost,
      required int serverPort,
      required int webSocketPort,
      required String scheme,
      String? pinnedFingerprint,
      String? authToken,
      required bool autoConnectWebSocket,
    }) => candidates.removeAt(0);

    late BackendNotifier notifier;
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith((ref) {
          notifier = BackendNotifier(ref, networkBackendFactory: factory);
          return notifier;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(backendProvider);

    final firstFuture = notifier.connect('first-host', 8080);
    final firstExpectation = expectLater(
      firstFuture,
      throwsA(isA<BackendTransitionSupersededException>()),
    );
    await _waitUntil(() => identical(notifier.currentBackend, first));

    final secondFuture = notifier.connect('second-host', 8080);
    await _waitUntil(() => identical(notifier.currentBackend, second));

    secondConnected = true;
    secondConnect.complete();
    await secondFuture;
    expect(notifier.currentBackend, same(second));

    firstConnected = false;
    firstConnect.completeError(StateError('old host failed'));
    await firstExpectation;
    expect(
      notifier.currentBackend,
      same(second),
      reason: 'the stale rollback must not replace the newer live backend',
    );
  });
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}
