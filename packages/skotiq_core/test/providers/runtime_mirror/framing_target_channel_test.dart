// The target on the host's Framing screen is one value a host and its linked
// clients both show, including on a client that links after it was chosen.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/in_memory_database.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Framing without the survey download, counting the downloads asked for.
class _CountingFramingNotifier extends FramingNotifier {
  _CountingFramingNotifier(super.ref);

  int surveyLoads = 0;

  @override
  Future<void> loadSurveyImage({double? canvasWidthLogicalPx}) async {
    surveyLoads++;
  }
}

ProviderContainer _host() {
  final backend = _MockFfiBackend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      framingProvider.overrideWith(_CountingFramingNotifier.new),
    ],
  );
  addTearDown(container.dispose);
  container.read(hostMutationEventHubProvider).wsBroadcast = (_) {};
  container.read(hostRuntimeMirrorProvider);
  return container;
}

({ProviderContainer client, _MockNetworkBackend backend}) _linkedTo(
  ProviderContainer host,
) {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.getHostRuntimeState()).thenAnswer(
    (_) async => host.read(hostRuntimeStateStoreProvider).snapshot(),
  );
  when(
    () => backend.framingSetTarget(
      ra: any(named: 'ra'),
      dec: any(named: 'dec'),
      name: any(named: 'name'),
    ),
  ).thenAnswer((_) async {});
  final client = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      framingProvider.overrideWith(_CountingFramingNotifier.new),
    ],
  );
  addTearDown(client.dispose);
  return (client: client, backend: backend);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('is in the shared list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      runtimeChannelFor(
        container.read(runtimeMirrorChannelsProvider),
        'framingTarget',
      ),
      isA<FramingTargetChannel>(),
    );
  });

  test('a client that links after the host chose a target shows it, without '
      'sending it back', () async {
    final host = _host();
    host
        .read(framingProvider.notifier)
        .setTargetCoordinates(0.7123, 41.269, name: 'M31');
    await Future<void>.delayed(Duration.zero);

    final link = _linkedTo(host);
    await hydrateHostRuntimeState(link.client, link.backend);

    final shown = link.client.read(framingProvider).target!;
    expect(shown.name, 'M31');
    expect(shown.raHours, closeTo(0.7123, 1e-9));
    expect(shown.decDegrees, closeTo(41.269, 1e-9));
    verifyNever(
      () => link.backend.framingSetTarget(
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        name: any(named: 'name'),
      ),
    );
  });

  test('the host clearing its target leaves the client its own', () async {
    final host = _host();
    final link = _linkedTo(host);
    link.client
        .read(framingProvider.notifier)
        .setTargetCoordinates(5.588, -5.39, name: 'M42');
    await hydrateHostRuntimeState(link.client, link.backend);
    expect(link.client.read(framingProvider).target?.name, 'M42');
  });

  test('the echo of a target this client set does not reload it', () async {
    final host = _host();
    final link = _linkedTo(host);
    final framing =
        link.client.read(framingProvider.notifier) as _CountingFramingNotifier;
    framing.setTargetCoordinates(5.588, -5.39, name: 'M42');
    final loads = framing.surveyLoads;

    // The host takes the client's target, as its set-target endpoint does.
    host
        .read(framingProvider.notifier)
        .setTargetCoordinates(5.588, -5.39, name: 'M42');
    await Future<void>.delayed(Duration.zero);
    await hydrateHostRuntimeState(link.client, link.backend);

    expect(framing.surveyLoads, loads);
    expect(link.client.read(framingProvider).target?.name, 'M42');
  });
}
