// The equipment error payload also carries notices: a camera that does not
// report its pixel size was shown as "Device error" although its frames are
// taken and saved.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _equipmentError(EventSeverity severity) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: severity,
  category: EventCategory.equipment,
  payload: const EventPayload.equipment(
    EquipmentEvent.error(
      deviceType: 'Camera',
      deviceId: 'native:fli:0',
      message: 'CCD47-10 does not report its pixel size',
    ),
  ),
);

void main() {
  test('an equipment error below error severity is titled as a notice', () {
    expect(
      {
        for (final severity in EventSeverity.values)
          severity: skotiqEventDisplayTitle(_equipmentError(severity)),
      },
      {
        EventSeverity.info: 'Device notice',
        EventSeverity.warning: 'Device notice',
        EventSeverity.error: 'Device error',
        EventSeverity.critical: 'Device error',
      },
    );
  });
}
