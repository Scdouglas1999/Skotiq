import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

SkotiqEvent _fired(SequencerTriggerAction action) => SkotiqEvent(
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

SequencerTriggerAction? _decodedAction(Object? wireAction) {
  final payload = decodeEventPayload(EventCategory.sequencer, 'TriggerFired', {
    'trigger_id': 'meridian_flip',
    'trigger_name': 'Meridian Flip',
    'action': wireAction,
  }, severity: EventSeverity.info);
  return switch (payload) {
    EventPayload_Sequencer(
      field0: SequencerEvent_TriggerFired(:final action),
    ) =>
      action,
    _ => null,
  };
}

void main() {
  test('a meridian flip trigger reads in plain words', () {
    expect(
      skotiqEventDisplayDetail(_fired(SequencerTriggerAction.meridianFlip)),
      'Meridian Flip → flip the mount',
    );
  });

  test('every action reads as plain words', () {
    for (final action in SequencerTriggerAction.values) {
      expect(
        triggerActionText(action),
        matches(RegExp(r'^[a-z ]+$')),
        reason: '$action',
      );
    }
  });

  test('the wire carries the executor names the host has always sent', () {
    for (final action in SequencerTriggerAction.values) {
      final (_, data) = encodeEventPayload(_fired(action).payload);
      expect(_decodedAction(data['action']), action);
    }
    final (_, parked) = encodeEventPayload(
      _fired(SequencerTriggerAction.parkAndAbort).payload,
    );
    expect(parked['action'], 'ParkAndAbort');
  });

  // An older host sent the action's Rust debug form.
  test('an action an older host spelled another way reads as a notice', () {
    expect(
      _decodedAction(
        'MeridianFlip(MeridianFlipConfig { trigger_method: '
        'MinutesPastMeridian, minutes_past_meridian: 20.0 })',
      ),
      SequencerTriggerAction.notify,
    );
  });
}
