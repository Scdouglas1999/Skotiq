// qa-pair QP-23: the "Add rotator, dome, flat panel, weather" tile kept
// offering a rotator with one connected, and a linked client's Discovered
// devices read "0 found · Never scanned" beside a host that had found 11.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_app/screens/equipment/widgets/discovery_panel.dart';
import 'package:skotiq_app/screens/shell/widgets/rig_card.dart';
import 'package:flutter/widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _CountingDiscovery extends UnifiedDiscoveryNotifier {
  _CountingDiscovery(super.ref);

  int scans = 0;

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async =>
      scans++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the add tile names only equipment not yet connected', () {
    expect(
      addEquipmentLabel(
        rotator: false,
        dome: false,
        flatPanel: false,
        weather: false,
      ),
      'Add rotator, dome, flat panel, weather',
    );
    expect(
      addEquipmentLabel(
        rotator: true,
        dome: false,
        flatPanel: false,
        weather: true,
      ),
      'Add dome, flat panel',
    );
    expect(
      addEquipmentLabel(
        rotator: true,
        dome: true,
        flatPanel: true,
        weather: true,
      ),
      'Add equipment',
    );
  });

  testWidgets('a linked client reads the host discovery once on open',
      (tester) async {
    late _CountingDiscovery discovery;
    await pumpAppScreen(
      tester,
      const DiscoveryPanel(),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _BackendNotifier(ref, _MockNetworkBackend()),
        ),
        unifiedDiscoveryProvider.overrideWith((ref) {
          return discovery = _CountingDiscovery(ref);
        }),
      ],
    );
    await tester.pump();
    await tester.pump();
    expect(discovery.scans, 1);
  });

  // The rail's rig card listed no rotator, so with one connected it read one
  // device fewer than the Equipment screen.
  testWidgets('the rig card counts a connected rotator', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Column(mainAxisSize: MainAxisSize.min, children: [
        RigCard(isExpanded: false),
      ]),
      size: const Size(2600, 900),
      settle: false,
    );
    final rotator = handle.container.read(rotatorStateProvider.notifier);
    rotator.setConnecting('sim_rotator_1', 'Simulated Rotator');
    rotator.setConnected();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'Equipment: 1 connected')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
