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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';
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
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    titles.add(title);
    bodies.add(body);
    return NotificationResult.ok();
  }
}

SkotiqEvent _disconnect(String deviceId, String deviceType) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.warning,
      category: EventCategory.equipment,
      eventType: 'Disconnected',
      data: {'device_id': deviceId, 'device_type': deviceType},
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
    expect(body, contains('Built-in Multi-Star Guider'));
    expect(body, contains('disconnected'));
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
    expect(body, contains('disconnected'));
  });

  test('an event with no device id at all still reads as a sentence', () async {
    final body = await _renderedBody(_disconnect('', 'Mount'));
    expect(body, contains('disconnected'));
    expect(body.trim(), isNot(startsWith('disconnected')));
    expect(body, isNot(contains('  ')));
  });

  test(
    'the default disconnect template does not reference the raw id',
    () async {
      // Reads the shipped source: a body template that reaches for
      // `equipment.device_id` is the defect, whatever it renders today.
      final source = await _routerSource();
      // The DEFINITION, not a call site: the router calls the same helper by
      // name for the stop templates, and those calls sit above it in the file.
      final bodyFn = source.indexOf(
        'static String _defaultBodyTemplate(NotificationCategory',
      );
      expect(bodyFn, greaterThan(0), reason: 'body-template function moved');
      final armStart = source.indexOf(
        'NotificationCategory.equipmentDisconnected:',
        bodyFn,
      );
      expect(armStart, greaterThan(0), reason: 'disconnect body arm moved');
      final arm = source.substring(
        armStart,
        source.indexOf('case NotificationCategory', armStart + 1),
      );
      expect(
        arm,
        isNot(contains('equipment.device_id')),
        reason: 'the operator-facing template must use the name',
      );
      expect(arm, contains('equipment.device_name'));
    },
  );
}

Future<String> _routerSource() async {
  final candidates = <String>[
    'lib/src/services/notification/notification_router.dart',
    'packages/skotiq_core/lib/src/services/notification/notification_router.dart',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.readAsString();
  }
  fail('could not locate notification_router.dart from ${Directory.current}');
}
