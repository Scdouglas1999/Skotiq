// The connect check's "unverified" report marks a device until it connects
// again or disconnects, over both transports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/event_wire.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

bridge.EventPayload _equipment(bridge.EquipmentEvent e) =>
    bridge.EventPayload.equipment(e);

void main() {
  test('the property and field words are the connect check\'s', () {
    final words =
        jsonDecode(
              File(
                '../../test_fixtures/wire_words/connect_check.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(unverifiedDeviceProperty, words['property']);
    // The fields this file's events name are ones the check reports.
    expect(
      words['fields'] as List,
      containsAll(<String>['pier side', 'clock', 'position']),
    );
  });

  for (final path in EventPath.values) {
    test('a device stays marked until it connects again ($path)', () async {
      final events = StreamController<SkotiqEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      final seen = <String>[];
      container.listen(
        unverifiedDeviceFieldsProvider,
        (_, next) => seen.add('$next'),
        fireImmediately: true,
      );

      Future<void> send(bridge.EquipmentEvent e) async {
        events.add(wireEventOver(path, _equipment(e)));
        await Future<void>.delayed(Duration.zero);
      }

      await send(
        const bridge.EquipmentEvent.connected(
          deviceType: 'mount',
          deviceId: 'mount-1',
          deviceName: 'Mount',
        ),
      );
      await send(
        const bridge.EquipmentEvent.propertyChanged(
          deviceType: 'mount',
          deviceId: 'mount-1',
          property: 'Unverified',
          value: 'pier side,clock',
        ),
      );
      await send(
        const bridge.EquipmentEvent.propertyChanged(
          deviceType: 'focuser',
          deviceId: 'foc-1',
          property: 'Unverified',
          value: 'position',
        ),
      );
      await send(
        const bridge.EquipmentEvent.propertyChanged(
          deviceType: 'focuser',
          deviceId: 'foc-1',
          property: 'Position',
          value: '100',
        ),
      );
      await send(
        const bridge.EquipmentEvent.disconnected(
          deviceType: 'focuser',
          deviceId: 'foc-1',
        ),
      );
      await send(
        const bridge.EquipmentEvent.connecting(
          deviceType: 'mount',
          deviceId: 'mount-1',
          deviceName: 'Mount',
        ),
      );

      expect(seen, [
        '{}',
        '{mount-1: [pier side, clock]}',
        '{mount-1: [pier side, clock], foc-1: [position]}',
        '{mount-1: [pier side, clock]}',
        '{}',
      ]);
    });
  }

  test('the card text names the fields and what to do', () {
    expect(
      unverifiedDeviceText('focuser', ['position']),
      "Not verified at connect: position. The focuser's report disagreed "
      'with what Skotiq recorded or measured; Skotiq shows the report and '
      'changed nothing. Check the focuser itself; the Log has both values.',
    );
  });
}
