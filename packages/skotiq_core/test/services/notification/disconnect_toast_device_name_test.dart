// The disconnect toast never prints a raw device id.
//
// A body template that interpolates `equipment.device_id` renders "Equipment
// disconnected / Guider native:builtin_guider:multi_star disconnected." —
// dumping wire identifiers on the one surface an operator sees at 2 a.m., even
// though `friendlyNameFromDeviceId` resolves that id.
//
// The counter-input is encoded literally: the four ids an operator can produce
// with no hardware attached must not appear ANYWHERE in a rendered disconnect
// body, and the assertion is a pattern over the whole body rather than an
// equality against one expected sentence — so a template that reaches for
// `${equipment.device_id}` again fails here even if it words the rest
// differently.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';
import 'package:skotiq_core/src/services/notification/notification_presentation.dart';
import 'package:skotiq_core/src/services/notification/notification_router.dart';
import 'package:skotiq_core/src/services/notification/transports/notification_transport.dart';

class _RecordingTransport extends NotificationTransport {
  @override
  final NotificationTransportKind kind;
  final List<String> bodies = [];
  final List<String> titles = [];

  _RecordingTransport(this.kind);

  @override
  String get name => kind.label;

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    final title = message.title;
    final body = message.body;
    titles.add(title);
    bodies.add(body);
    return NotificationResult.ok();
  }
}

const _heartbeatMessage =
    'Device unresponsive after 3 heartbeat failures: timed out';

/// What the host publishes when a device's connection ends: no sentence.
SkotiqEvent _disconnected(String deviceId, String deviceType) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.error,
  category: EventCategory.equipment,
  eventType: 'Disconnected',
  data: {'device_id': deviceId, 'device_type': deviceType},
);

/// What the host's heartbeat publishes when a device stops answering.
SkotiqEvent _disconnect(String deviceId, String deviceType) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.error,
  category: EventCategory.equipment,
  eventType: 'Error',
  data: {
    'device_id': deviceId,
    'device_type': deviceType,
    'message': _heartbeatMessage,
  },
);

/// Anything that looks like a wire id rather than a device name.
final RegExp _rawIdShape = RegExp(
  r'native:|ascom:|alpaca:|indi:|simulator:|sim_[a-z_]+_\d',
  caseSensitive: false,
);

/// Render a disconnect notification exactly the way the app does: classify the
/// backend event, then route it through the real router with the default
/// templates.
Future<String> _renderedBody(SkotiqEvent event) async {
  final classified = NotificationEventClassifier.classify(event);
  expect(classified, isNotNull, reason: 'the event must classify at all');
  expect(classified!.category, NotificationCategory.equipmentDisconnected);

  final transport = _RecordingTransport(NotificationTransportKind.discord);
  final matrix = NotificationRoutingMatrix.defaults().withRule(
    NotificationCategory.equipmentDisconnected,
    const NotificationRoutingRule(
      transports: [NotificationTransportKind.discord],
    ),
  );
  final router = NotificationRouter(transports: [transport], matrix: matrix);
  router.route(
    classified.category,
    classified.context,
    severity: classified.severity,
  );
  await Future<void>.delayed(Duration.zero);
  expect(transport.bodies, hasLength(1));
  final body = transport.bodies.single;
  await router.dispose();
  return body;
}

void main() {
  test(
    'the classifier resolves a friendly name for the disconnected device',
    () {
      final classified = NotificationEventClassifier.classify(
        _disconnect('native:builtin_guider:multi_star', 'Guider'),
      );
      expect(
        classified!.context['equipment.device_name'],
        'Built-in Multi-Star Guider',
      );
    },
  );

  test('the built-in guider disconnect names the guider, not its id', () async {
    final body = await _renderedBody(
      _disconnect('native:builtin_guider:multi_star', 'Guider'),
    );
    expect(body, 'Built-in Multi-Star Guider: $_heartbeatMessage');
    expect(
      body,
      isNot(matches(_rawIdShape)),
      reason: 'the toast body must never carry a wire id',
    );
  });

  test('every hardware-free device id renders as its display name', () async {
    const cases = <String, (String, String)>{
      'native:builtin_guider:multi_star': (
        'Guider',
        'Built-in Multi-Star Guider',
      ),
      'sim_camera_1': ('Camera', 'Simulated Camera'),
      'sim_filterwheel_1': ('FilterWheel', 'Simulated Filter Wheel'),
      'sim_focuser_1': ('Focuser', 'Simulated Focuser'),
    };
    for (final entry in cases.entries) {
      final body = await _renderedBody(_disconnect(entry.key, entry.value.$1));
      expect(
        body,
        contains(entry.value.$2),
        reason: '${entry.key} should render as ${entry.value.$2}',
      );
      expect(
        body,
        isNot(contains(entry.key)),
        reason: '${entry.key} must not appear raw in the body',
      );
      expect(body, isNot(matches(_rawIdShape)));
    }
  });

  test('an unknown id still degrades to something readable', () async {
    final body = await _renderedBody(
      _disconnect('ascom:ASCOM.Simulator.Camera', 'Camera'),
    );
    // friendlyNameFromDeviceId already handles ASCOM ProgIDs; the point of the
    // case is that the raw `ascom:` prefix never survives to the operator.
    expect(body, isNot(matches(_rawIdShape)));
    expect(body, contains(_heartbeatMessage));
  });

  test('an event with no device id at all still reads as a sentence', () async {
    final body = await _renderedBody(_disconnect('', 'Mount'));
    expect(body, 'Mount: $_heartbeatMessage');
  });

  test('a disconnect that carries no message says the device disconnected',
      () async {
    expect(
      await _renderedBody(_disconnected('sim_camera_1', 'Camera')),
      'Simulated Camera disconnected.',
    );
    expect(await _renderedBody(_disconnected('', 'Mount')), 'Mount disconnected.');
  });

  test('an error with an empty message says the device disconnected',
      () async {
    final event = _disconnect('sim_focuser_1', 'Focuser');
    event.data['message'] = '  ';
    expect(await _renderedBody(event), 'Simulated Focuser disconnected.');
  });

  test('the default disconnect template does not reference the raw id', () {
    final body = NotificationPresentation.of(
      NotificationCategory.equipmentDisconnected,
    ).body;
    expect(
      body,
      isNot(contains('equipment.device_id')),
      reason: 'the operator-facing template must use the name',
    );
    expect(body, contains('equipment.summary'));
  });
}
