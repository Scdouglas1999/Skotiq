// The host tells its linked clients which plate solvers it has and which one
// its operator chose, so a client's Plate Solving page shows the host's setup
// without asking for it, and follows a change made on the host.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'mirror_link.dart';

const _astapOnly = PlateSolverDetection(
  astapPath: '/opt/astap/astap',
  catalogName: 'D50',
  catalogPath: '/opt/astap',
);

const _astapChosen = PlateSolverPreference(choice: PlateSolverChoice.astap);

/// Let the host's solver reads finish and the providers built on them
/// publish.
Future<void> hostSettled(MirrorHost host) async {
  for (var i = 0; i < 3; i++) {
    await settle();
    await host.container.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MirrorHost> solverHost() async {
    final host = mirrorHost();
    when(
      () => host.backend.detectPlateSolvers(),
    ).thenAnswer((_) async => _astapOnly);
    when(
      () => host.backend.getPlateSolverConfig(),
    ).thenAnswer((_) async => _astapChosen);
    // The host read its solvers when it started publishing.
    host.container
      ..invalidate(plateSolverDetectionProvider)
      ..invalidate(plateSolverPreferenceProvider);
    await hostSettled(host);
    return host;
  }

  Future<void> deliver(MirrorHost host, MirrorClient client) async {
    await hostSettled(host);
    for (final update in host.sent) {
      applyHostRuntimeUpdate(
        client.container,
        update,
        networkBackend: client.backend,
      );
    }
    host.sent.clear();
  }

  test('a client that links shows the host\'s solvers without asking for '
      'them', () async {
    final host = await solverHost();

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    client.container.listen(plateSolverDetectionProvider, (_, _) {});

    final detection = await client.container.read(
      plateSolverDetectionProvider.future,
    );
    final preference = await client.container.read(
      plateSolverPreferenceProvider.future,
    );
    expect(detection.astapPath, '/opt/astap/astap');
    expect(detection.catalogName, 'D50');
    expect(preference.choice, PlateSolverChoice.astap);
    expect(client.container.read(plateSolverReadyProvider), isTrue);
    verifyNever(() => client.backend.detectPlateSolvers());
    verifyNever(() => client.backend.getPlateSolverConfig());
  });

  test('a solver set up on the host reaches a linked client', () async {
    final host = await solverHost();
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    client.container.listen(plateSolverDetectionProvider, (_, _) {});
    host.sent.clear();

    // What the host's config handler does after a save.
    when(() => host.backend.detectPlateSolvers()).thenAnswer(
      (_) async => const PlateSolverDetection(
        astapPath: '/opt/astap/astap',
        astrometryPath: '/usr/bin/solve-field',
        catalogName: 'D50',
        catalogPath: '/opt/astap',
      ),
    );
    when(() => host.backend.getPlateSolverConfig()).thenAnswer(
      (_) async =>
          const PlateSolverPreference(choice: PlateSolverChoice.astrometry),
    );
    host.container
      ..invalidate(plateSolverPreferenceProvider)
      ..invalidate(plateSolverDetectionProvider);
    await deliver(host, client);

    final detection = await client.container.read(
      plateSolverDetectionProvider.future,
    );
    final preference = await client.container.read(
      plateSolverPreferenceProvider.future,
    );
    expect(detection.astrometryPath, '/usr/bin/solve-field');
    expect(preference.choice, PlateSolverChoice.astrometry);
    verifyNever(() => client.backend.detectPlateSolvers());
  });

  test('until the host has told it, a client shows its solvers as not known '
      'and asks no one', () async {
    final client = mirrorClient(null, snapshot: () => const []);
    await hydrateHostRuntimeState(client.container, client.backend);
    client.container.listen(plateSolverDetectionProvider, (_, _) {});
    client.container.listen(plateSolverPreferenceProvider, (_, _) {});
    await settle();

    expect(client.container.read(plateSolverDetectionProvider).isLoading, isTrue);
    expect(client.container.read(plateSolverReadyProvider), isNull);
    verifyNever(() => client.backend.detectPlateSolvers());
    verifyNever(() => client.backend.getPlateSolverConfig());
  });

  test('a rescan on a client shows the host\'s answer at once', () async {
    final client = mirrorClient(null, snapshot: () => const []);
    when(
      () => client.backend.detectPlateSolvers(),
    ).thenAnswer((_) async => _astapOnly);
    await hydrateHostRuntimeState(client.container, client.backend);
    client.container.listen(plateSolverDetectionProvider, (_, _) {});

    final rescanned = await client.container
        .read(plateSolverSettingsNotifierProvider.notifier)
        .rescan();

    expect(rescanned, isTrue);
    final detection = await client.container.read(
      plateSolverDetectionProvider.future,
    );
    expect(detection.astapPath, '/opt/astap/astap');
  });
}
