// Tonight's log read "Guiding settled · RMS 0.00" right after guiding started.
// PHD2's settle reports no RMS; the built-in guider's is
// in guide-camera pixels.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _guiding(GuidingEvent event) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.guiding,
  payload: EventPayload.guiding(event),
);

void main() {
  test('a settle with no measured RMS states none', () {
    final event = _guiding(const GuidingEvent.settled());
    expect(skotiqEventDisplayTitle(event), 'Guiding settled');
    expect(skotiqEventDisplayDetail(event), isEmpty);
  });

  test('a measured RMS reads in the pixels it was measured in', () {
    expect(
      skotiqEventDisplayDetail(_guiding(const GuidingEvent.settled(rms: 0.42))),
      'RMS 0.42 px',
    );
  });
}
