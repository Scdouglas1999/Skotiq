import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/remote_host.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/host_role.dart';

class _Backends extends BackendNotifier {
  _Backends(super.ref, SkotiqBackend initial) {
    state = initial;
  }

  void install(SkotiqBackend backend) => state = backend;
}

void main() {
  final sideProvider = hostRoleProvider<String>(
    here: (ref) => 'here',
    linked: (ref, host) => 'linked to ${host.link.serverHost}',
  );

  NetworkBackend linkTo(String host) => NetworkBackend(
    serverHost: host,
    serverPort: 8080,
    webSocketPort: 8080,
    autoConnectWebSocket: false,
  );

  test('a process with no link serves host data from its own store', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(remoteHostProvider), isNull);
    expect(container.read(sideProvider), 'here');
  });

  test('the side follows the backend, and is chosen once per backend', () {
    late _Backends backends;
    final first = linkTo('rig-a');
    final second = linkTo('rig-b');
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => backends = _Backends(ref, DisconnectedBackend()),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    final sides = <String>[];
    container.listen(sideProvider, (_, next) => sides.add(next));
    expect(container.read(sideProvider), 'here');

    backends.install(first);
    expect(container.read(sideProvider), 'linked to rig-a');
    expect(
      container.read(remoteHostProvider),
      same(first.remoteHost),
      reason: 'one RemoteHost per backend, so roles compare by identity',
    );

    backends.install(second);
    expect(container.read(sideProvider), 'linked to rig-b');

    backends.install(DisconnectedBackend());
    expect(container.read(sideProvider), 'here');
    expect(sides, ['linked to rig-a', 'linked to rig-b', 'here']);
  });
}
