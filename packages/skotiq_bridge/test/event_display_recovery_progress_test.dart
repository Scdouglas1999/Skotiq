import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _progress(int attemptCount, int maxAttempts) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: EventSeverity.warning,
  category: EventCategory.sequencer,
  payload: EventPayload.sequencer(
    SequencerEvent.recoveryProgress(
      startedAtIso: '2026-11-27T03:00:00Z',
      causeKind: 'SlewFailed',
      attemptCount: attemptCount,
      maxAttempts: maxAttempts,
      retryIntervalSecs: 30,
      maxDurationSecs: 300,
      phase: 'Attempting',
    ),
  ),
);

void main() {
  test('a recovery attempt is counted with its English ordinal', () {
    expect(
      [
        for (var attempt = 0; attempt < 13; attempt++)
          skotiqEventDisplayDetail(_progress(attempt, 13)),
      ],
      [
        for (final ordinal in [
          '1st',
          '2nd',
          '3rd',
          '4th',
          '5th',
          '6th',
          '7th',
          '8th',
          '9th',
          '10th',
          '11th',
          '12th',
          '13th',
        ])
          'SlewFailed · Attempting ($ordinal of 13)',
      ],
    );
    expect(
      skotiqEventDisplayDetail(_progress(20, 30)),
      'SlewFailed · Attempting (21st of 30)',
    );
    expect(
      skotiqEventDisplayDetail(_progress(111, 120)),
      'SlewFailed · Attempting (112th of 120)',
    );
  });
}
