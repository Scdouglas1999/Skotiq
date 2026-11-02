// The executor's preflight advisory (a meridian-flip re-center with no plate
// solver) rides the error payload at warning severity; the Tonight log
// titled it "Sequencer error" although the run went on normally
// (qa-pair QP-14).
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _sequencerError(EventSeverity severity) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: severity,
  category: EventCategory.sequencer,
  payload: const EventPayload.sequencer(
    SequencerEvent.error(message: 'advisory'),
  ),
);

void main() {
  test('a warning on the error payload reads as a notice', () {
    expect(
      skotiqEventDisplayTitle(_sequencerError(EventSeverity.warning)),
      'Sequencer notice',
    );
  });

  test('a real sequencer error still reads as an error', () {
    expect(
      skotiqEventDisplayTitle(_sequencerError(EventSeverity.error)),
      'Sequencer error',
    );
  });
}
