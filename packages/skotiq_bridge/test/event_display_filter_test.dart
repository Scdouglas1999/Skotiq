// Slots are the wheel's
// 0-based positions; the Log names them.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _equipment(EquipmentEvent event) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.equipment,
  payload: EventPayload.equipment(event),
);

void main() {
  test('a filter change names both filters', () {
    final event = _equipment(
      const EquipmentEvent.filterChanging(
        deviceId: 'wheel',
        fromPosition: 0,
        toPosition: 1,
        filterName: 'R',
        fromFilterName: 'L',
      ),
    );
    expect(skotiqEventDisplayTitle(event), 'Filter changing');
    expect(skotiqEventDisplayDetail(event), 'L → R');
    expect(
      skotiqEventDisplayDetail(
        _equipment(
          const EquipmentEvent.filterChanged(
            deviceId: 'wheel',
            position: 1,
            filterName: 'R',
          ),
        ),
      ),
      'R',
    );
  });

  test('an unnamed slot is counted from 1, as Equipment counts it', () {
    expect(
      skotiqEventDisplayDetail(
        _equipment(
          const EquipmentEvent.filterChanging(
            deviceId: 'wheel',
            fromPosition: 0,
            toPosition: 1,
          ),
        ),
      ),
      'slot 1 → slot 2',
    );
    expect(
      skotiqEventDisplayDetail(
        _equipment(
          const EquipmentEvent.filterChanging(
            deviceId: 'wheel',
            fromPosition: -1,
            toPosition: 1,
            filterName: 'R',
          ),
        ),
      ),
      'unknown slot → R',
    );
    expect(
      skotiqEventDisplayDetail(
        _equipment(
          const EquipmentEvent.filterChanged(deviceId: 'wheel', position: 0),
        ),
      ),
      'slot 1',
    );
  });
}
