// The executor announces the pier change before the flip's verdict. Read as
// any other outcome it would be titled "Meridian flip FAILED" for a mount
// that just reached its new side.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _flip(String outcome) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  payload: EventPayload.sequencer(
    SequencerEvent.meridianFlipOutcome(
      outcome: outcome,
      targetName: 'NGC 7814',
      newPierSide: 'East',
      durationSecs: 0,
      attempts: 1,
      failedSteps: const [],
    ),
  ),
);

void main() {
  test('a pier change reads as the mount on its new side', () {
    final event = _flip('pier_changed');
    expect(
      skotiqEventDisplayTitle(event),
      'Meridian flip: mount on the new pier side',
    );
    expect(skotiqEventDisplayDetail(event), 'NGC 7814 · pier east');
  });

  test('an unknown outcome still reads as a failure', () {
    expect(skotiqEventDisplayTitle(_flip('failed')), 'Meridian flip FAILED');
  });
}
