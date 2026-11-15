// What a host event raises is decided by the event's kind and the severity the
// host published it at, as the host sends them.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

SkotiqEvent _wire(
  bridge.EventPayload payload,
  EventCategory category,
  EventSeverity severity,
) {
  final (type, data) = bridge.encodeEventPayload(payload);
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: category,
    eventType: type,
    data: Map<String, dynamic>.from(data),
  );
}

ClassifiedNotification? _equipment(
  bridge.EquipmentEvent event,
  EventSeverity severity,
) => NotificationEventClassifier.classify(
  _wire(bridge.EventPayload.equipment(event), EventCategory.equipment, severity),
);

ClassifiedNotification? _guiding(
  bridge.GuidingEvent event,
  EventSeverity severity,
) => NotificationEventClassifier.classify(
  _wire(bridge.EventPayload.guiding(event), EventCategory.guiding, severity),
);

ClassifiedNotification? _flip(bridge.FlipOutcome outcome, {int attempts = 1}) =>
    NotificationEventClassifier.classify(
      _wire(
        bridge.EventPayload.sequencer(
          bridge.SequencerEvent.meridianFlipOutcome(
            outcome: outcome,
            targetName: 'M31',
            newPierSide: 'West',
            durationSecs: 200,
            attempts: attempts,
            failedSteps: const [],
            actionTaken: 'continued',
          ),
        ),
        EventCategory.sequencer,
        EventSeverity.info,
      ),
    );

void main() {
  const camera = 'gphoto2:canon_eos_rp';

  test('a notice about a connected camera raises nothing', () {
    expect(
      _equipment(
        const bridge.EquipmentEvent.error(
          deviceType: 'camera',
          deviceId: camera,
          message: 'Canon EOS RP does not report its pixel size.',
        ),
        EventSeverity.warning,
      ),
      isNull,
    );
  });

  test('a device that stopped answering is a lost device', () {
    expect(
      _equipment(
        const bridge.EquipmentEvent.error(
          deviceType: 'camera',
          deviceId: camera,
          message: 'Device unresponsive after 3 heartbeat failures',
        ),
        EventSeverity.error,
      )?.category,
      NotificationCategory.equipmentDisconnected,
    );
  });

  test("the operator's own disconnect raises nothing", () {
    expect(
      _equipment(
        const bridge.EquipmentEvent.disconnected(
          deviceType: 'camera',
          deviceId: camera,
        ),
        EventSeverity.info,
      ),
      isNull,
    );
    expect(
      _guiding(const bridge.GuidingEvent.disconnected(), EventSeverity.info),
      isNull,
    );
  });

  test('a guider that dropped its connection or lost its star is told', () {
    for (final event in const [
      bridge.GuidingEvent.disconnected(),
      bridge.GuidingEvent.lostStar(),
    ]) {
      expect(
        _guiding(event, EventSeverity.warning)?.category,
        NotificationCategory.guidingLost,
      );
    }
  });

  test('a meridian flip is told once, from its successful verdict', () {
    final progress = NotificationEventClassifier.classify(
      _wire(
        const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.instructionProgress(
            nodeId: 'flip',
            instruction: 'Meridian flip',
            progressPercent: 40,
            detail: 'Meridian flip attempt 2/4 failed, retrying',
          ),
        ),
        EventCategory.sequencer,
        EventSeverity.info,
      ),
    );
    expect(progress, isNull);
    expect(_flip(bridge.FlipOutcome.pierChanged), isNull);
    expect(_flip(bridge.FlipOutcome.failed), isNull);
    expect(_flip(bridge.FlipOutcome.aborted), isNull);

    final done = _flip(bridge.FlipOutcome.success, attempts: 2)!;
    expect(done.category, NotificationCategory.meridianFlipPerformed);
    final body = renderNotificationTemplate(
      NotificationPresentation.of(done.category).body,
      NotificationContext(done.context),
    );
    expect(body, 'Meridian flip completed for M31 after 2 attempts.');
  });
}
