import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/connection_quality_provider.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'reconnect clears stale latency until a fresh heartbeat arrives',
    () async {
      final states = StreamController<BackendConnectionState>.broadcast();
      final latencies = StreamController<Duration>.broadcast();
      final backend = _MockNetworkBackend();
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.connected);
      when(
        () => backend.lastLatency,
      ).thenReturn(const Duration(milliseconds: 42));
      when(() => backend.serverHost).thenReturn('rig.local');
      when(() => backend.isRemoteHost).thenReturn(false);
      when(
        () => backend.connectionStateStream,
      ).thenAnswer((_) => states.stream);
      when(() => backend.latencyStream).thenAnswer((_) => latencies.stream);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(states.close);
      addTearDown(latencies.close);
      final subscription = container.listen(
        connectionQualityProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _pump();

      expect(
        container.read(connectionQualityProvider).valueOrNull?.latencyMs,
        42,
      );

      states.add(BackendConnectionState.reconnecting);
      await _pump();
      final reconnecting = container
          .read(connectionQualityProvider)
          .requireValue;
      expect(reconnecting.liveness, ConnectionLiveness.reconnecting);
      expect(reconnecting.latency, isNull);

      states.add(BackendConnectionState.connected);
      await _pump();
      expect(
        container.read(connectionQualityProvider).requireValue.latency,
        isNull,
      );

      latencies.add(const Duration(milliseconds: 18));
      await _pump();
      expect(
        container.read(connectionQualityProvider).requireValue.latencyMs,
        18,
      );
    },
  );

  test('telemetry stream errors emit a remote error snapshot', () async {
    final states = StreamController<BackendConnectionState>.broadcast();
    final backend = _MockNetworkBackend();
    when(
      () => backend.connectionState,
    ).thenReturn(BackendConnectionState.connected);
    when(
      () => backend.lastLatency,
    ).thenReturn(const Duration(milliseconds: 25));
    when(() => backend.serverHost).thenReturn('remote-rig');
    when(() => backend.isRemoteHost).thenReturn(true);
    when(() => backend.connectionStateStream).thenAnswer((_) => states.stream);
    when(
      () => backend.latencyStream,
    ).thenAnswer((_) => const Stream<Duration>.empty());

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(states.close);
    final subscription = container.listen(
      connectionQualityProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await _pump();

    states.addError(StateError('connection telemetry failed'));
    await _pump();

    final async = container.read(connectionQualityProvider);
    expect(async.hasError, isFalse);
    expect(async.requireValue.mode, ConnectionMode.remote);
    expect(async.requireValue.liveness, ConnectionLiveness.error);
    expect(async.requireValue.remoteHost, 'remote-rig');
    expect(async.requireValue.latency, isNull);
  });

  // A rolled-back connect leaves a DisconnectedBackend installed. It is not a
  // NetworkBackend either, and folding it into the local snapshot told the
  // dashboard chip that this machine was driving the rig when nothing was.
  test('a DisconnectedBackend is not reported as local', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      connectionQualityProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await _pump();

    final quality = container.read(connectionQualityProvider).requireValue;
    expect(quality.mode, isNot(ConnectionMode.local));
    expect(quality.mode, ConnectionMode.none);
    expect(quality.isHealthy, isFalse);
  });
}
