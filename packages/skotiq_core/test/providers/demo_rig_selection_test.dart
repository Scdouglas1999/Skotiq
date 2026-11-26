import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_backend.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_connection_state.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

void main() {
  late ProviderContainer container;
  late BackendNotifier notifier;
  late List<NetworkBackend> hosts;

  setUp(() {
    hosts = [];
    NetworkBackend factory({
      required String serverHost,
      required int serverPort,
      required int webSocketPort,
      required String scheme,
      String? pinnedFingerprint,
      String? authToken,
      required bool autoConnectWebSocket,
    }) => hosts.removeAt(0);

    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    container = ProviderContainer(
      overrides: [
        // A backend swap resets the device slots, which reach the database.
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith((ref) {
          notifier = BackendNotifier(ref, networkBackendFactory: factory);
          return notifier;
        }),
      ],
    );
    container.read(backendProvider);
  });

  tearDown(() => container.dispose());

  NetworkBackend liveHost() {
    final host = _MockNetworkBackend();
    when(() => host.connect()).thenAnswer((_) async {});
    when(
      () => host.connectionState,
    ).thenReturn(BackendConnectionState.connected);
    when(() => host.isRemoteHost).thenReturn(false);
    when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
    hosts.add(host);
    return host;
  }

  Future<void> want(bool wanted) =>
      notifier.setDemoRigWanted(wanted, latitudeDeg: 40, longitudeDeg: -105);

  test('the demo rig replaces no backend, and turning it off puts no backend '
      'back', () async {
    expect(notifier.currentBackend, isA<DisconnectedBackend>());
    await want(true);
    expect(notifier.currentBackend, isA<DemoBackend>());
    await want(true);
    expect(notifier.currentBackend, isA<DemoBackend>());
    await want(false);
    expect(notifier.currentBackend, isA<DisconnectedBackend>());
  });

  test('a linked phone keeps its host; the demo rig starts when the link is '
      'let go', () async {
    final host = liveHost();
    await notifier.connect('rig', 8080);
    expect(notifier.currentBackend, same(host));

    await want(true);
    expect(
      notifier.currentBackend,
      same(host),
      reason: 'the setting never replaces a linked host',
    );

    await notifier.disconnect();
    expect(notifier.currentBackend, isA<DemoBackend>());
  });

  test('a link replaces the demo rig', () async {
    await want(true);
    final demo = notifier.currentBackend;
    expect(demo, isA<DemoBackend>());
    final host = liveHost();
    await notifier.connect('rig', 8080);
    expect(notifier.currentBackend, same(host));
  });
}
