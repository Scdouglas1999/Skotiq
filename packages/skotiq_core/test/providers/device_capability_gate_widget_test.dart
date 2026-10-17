// Widget-level smoke tests for capability gating.
//
// These tests do NOT try to pump the real Equipment / Imaging screens
// (those drag in the entire backend, database, and FFI loader).
// Instead they assemble a minimal Consumer widget that mirrors the
// gating pattern used in mount_tab.dart / mount_control_panel.dart and
// assert the visible/disabled state matches the gate's contract.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';
import 'package:skotiq_core/src/providers/equipment/device_capability_provider.dart';
import '../harness/in_memory_database.dart';

/// Test widget: shows a button that's gated on `canPark`. Mirrors the
/// pattern in mount_tab.dart so the gate's behaviour is exercised end-to-end
/// in a widget tree.
class _CapabilityGatedButton extends ConsumerWidget {
  final String deviceId;
  const _CapabilityGatedButton({required this.deviceId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(equipmentMountCapabilitiesProvider(deviceId));
    final canPark = gateCapability<MountCapabilities>(caps, (c) => c.canPark);
    return Column(
      children: [
        if (canPark)
          ElevatedButton(onPressed: () {}, child: const Text('Park'))
        else
          const Text('Park button hidden'),
      ],
    );
  }
}

Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('gated control renders when capability flag is TRUE', (
    tester,
  ) async {
    // Stub the FutureProvider.family by overriding it directly with a
    // resolved value. This decouples the test from the backend layer.
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        equipmentMountCapabilitiesProvider('mount:supports-park').overrideWith(
          (_) async => const MountCapabilities(canPark: true, canUnpark: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(
        container,
        const _CapabilityGatedButton(deviceId: 'mount:supports-park'),
      ),
    );
    // Let the FutureProvider resolve.
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Park'), findsOneWidget);
    expect(find.text('Park button hidden'), findsNothing);
  });

  testWidgets('gated control is hidden when capability flag is FALSE', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        equipmentMountCapabilitiesProvider(
          'mount:no-park',
        ).overrideWith((_) async => const MountCapabilities(canPark: false)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(container, const _CapabilityGatedButton(deviceId: 'mount:no-park')),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Park'), findsNothing);
    expect(find.text('Park button hidden'), findsOneWidget);
  });

  testWidgets('gated control is hidden when the capability query errors '
      '(fail-closed)', (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        equipmentMountCapabilitiesProvider('mount:broken').overrideWith(
          (_) => Future<MountCapabilities?>.error(StateError('driver crashed')),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(container, const _CapabilityGatedButton(deviceId: 'mount:broken')),
    );
    // Let the error propagate.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.widgetWithText(ElevatedButton, 'Park'),
      findsNothing,
      reason:
          'A driver that throws on capability query must fall back to the '
          'safest possible UI: the button is hidden.',
    );
    expect(find.text('Park button hidden'), findsOneWidget);
  });
}
