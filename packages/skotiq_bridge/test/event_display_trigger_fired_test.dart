// The rig's Log (2026-11-03) printed the executor's Rust debug form of a fired
// meridian flip trigger: "Trigger fired · Meridian Flip → MeridianFlip(
// MeridianFlipConfig { trigger_method: MinutesPastMeridian, ... })".
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _fired(String action) => SkotiqEvent(
  eventId: BigInt.one,
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  payload: EventPayload.sequencer(
    SequencerEvent.triggerFired(
      triggerId: 'meridian_flip',
      triggerName: 'Meridian Flip',
      action: action,
    ),
  ),
);

void main() {
  test('a meridian flip trigger reads in plain words', () {
    expect(
      skotiqEventDisplayDetail(_fired('MeridianFlip')),
      'Meridian Flip → flip the mount',
    );
  });

  test('an older host debug dump is cut to the action name', () {
    final detail = skotiqEventDisplayDetail(
      _fired(
        'MeridianFlip(MeridianFlipConfig { trigger_method: '
        'MinutesPastMeridian, minutes_past_meridian: 20.0 })',
      ),
    );
    expect(detail, 'Meridian Flip → flip the mount');
    expect(
      skotiqEventDisplayDetail(_fired('Retry { max_attempts: 3 }')),
      'Meridian Flip → retry',
    );
  });

  test('every action label has words, not a struct', () {
    for (final label in [
      'Continue',
      'Notify',
      'Pause',
      'Autofocus',
      'NextTarget',
      'ParkAndAbort',
      'Abort',
      'Dither',
      'Recenter',
    ]) {
      final text = triggerActionText(label);
      expect(text, isNot(label), reason: label);
      expect(text, isNot(contains('{')), reason: label);
    }
  });
}
