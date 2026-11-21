import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';

void main() {
  test('a rebuilt filter-wheel event is labeled with the friendly name', () {
    const raw = 'native:zwo_efw:0';
    final event = typedEventFromWire(
      const SkotiqEvent(
        timestamp: 1000,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'Connected',
        data: {'device_type': 'Filter Wheel', 'device_id': raw},
      ),
    );
    expect(event, isNotNull);
    expect(event!.deviceId, raw);
    final friendly = friendlyNameFromDeviceId(raw);
    final shown = humanizeDeviceIds('Filter Wheel · $raw', event);
    expect(shown, 'Filter Wheel · $friendly');
    expect(shown.contains(raw), isFalse);
  });
}
