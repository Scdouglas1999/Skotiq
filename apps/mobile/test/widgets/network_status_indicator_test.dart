import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_mobile/services/rig_connection.dart';
import 'package:skotiq_mobile/widgets/network_status_indicator.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

DiscoveredServer _rig(String name, String host) =>
    DiscoveredServer(name: name, host: host, webPort: 8099, mode: 'headless');

void main() {
  testWidgets('the indicator names the rig the phone is linked to now', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(connectedRigProvider.notifier).state = _rig(
      'Backyard rig',
      '192.168.1.20',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: Center(child: NetworkStatusIndicator())),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Backyard rig'), findsOneWidget);

    // A switch to another rig in the same session.
    container.read(connectedRigProvider.notifier).state = _rig(
      'Dark-site rig',
      '100.64.0.7',
    );
    await tester.pump();
    expect(find.text('Dark-site rig'), findsOneWidget);
    expect(find.text('Backyard rig'), findsNothing);
  });
}
