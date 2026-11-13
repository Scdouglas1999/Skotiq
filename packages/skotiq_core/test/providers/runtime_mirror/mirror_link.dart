// A host container and a client container linked to it through the host's
// runtime state, for the channel tests.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/in_memory_database.dart';

class MockHostBackend extends Mock implements FfiBackend {}

class MockLinkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

typedef MirrorHost = ({
  ProviderContainer container,
  MockHostBackend backend,
  StreamController<SkotiqEvent> events,
  List<HostRuntimeUpdate> sent,
});

/// A host that publishes its runtime channels; [sent] collects what it
/// broadcasts to linked clients.
MirrorHost mirrorHost() {
  final backend = MockHostBackend();
  final events = StreamController<SkotiqEvent>.broadcast();
  addTearDown(events.close);
  when(() => backend.eventStream).thenAnswer((_) => events.stream);
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  addTearDown(container.dispose);
  final sent = <HostRuntimeUpdate>[];
  container.read(hostMutationEventHubProvider).wsBroadcast = (event) {
    final update = HostRuntimeUpdate.fromJson(event.data);
    if (update != null) sent.add(update);
  };
  container.read(hostRuntimeMirrorProvider);
  return (container: container, backend: backend, events: events, sent: sent);
}

typedef MirrorClient = ({ProviderContainer container, MockLinkBackend backend});

/// A client linked to [host]: its runtime state read returns what [host]
/// holds now. [snapshot] replaces that, for a host of another version.
MirrorClient mirrorClient(
  ProviderContainer? host, {
  List<HostRuntimeUpdate> Function()? snapshot,
}) {
  final backend = MockLinkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.getHostRuntimeState()).thenAnswer(
    (_) async =>
        snapshot?.call() ??
        host!.read(hostRuntimeStateStoreProvider).snapshot(),
  );
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, backend: backend);
}

/// Let listeners and the publisher's coalescing timers run.
Future<void> settle([Duration wait = Duration.zero]) =>
    Future<void>.delayed(wait);
