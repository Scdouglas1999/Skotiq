import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';

void main() {
  group('NotificationCategory', () {
    test('storage keys roundtrip', () {
      for (final c in NotificationCategory.values) {
        expect(NotificationCategory.fromStorageKey(c.storageKey), c);
      }
    });

    test('fromStorageKey returns null for unknown', () {
      expect(NotificationCategory.fromStorageKey('not_a_thing'), isNull);
    });

    test('transientDiscovered is critical-by-default at critical severity', () {
      // First Light discoveries are time-critical (chase before fade): they
      // must be critical so they push to the phone and clear the default min
      // severity bar on the systemPush transport.
      expect(NotificationCategory.transientDiscovered.isCritical, isTrue);
      expect(
        NotificationCategory.transientDiscovered.defaultSeverity,
        EventSeverity.critical,
      );
    });
  });

  group('NotificationRoutingRule.fromJson', () {
    test('round-trips a full config', () {
      const rule = NotificationRoutingRule(
        transports: [
          NotificationTransportKind.pushover,
          NotificationTransportKind.discord,
        ],
        minSeverity: EventSeverity.warning,
        maxPerHour: 5,
        debounceSeconds: 30,
        titleTemplate: 'T',
        bodyTemplate: 'B',
        enabled: false,
      );
      final decoded = NotificationRoutingRule.fromJson(rule.toJson());
      expect(decoded, rule);
    });

    test('falls back to inApp if transports missing', () {
      final decoded = NotificationRoutingRule.fromJson(const {
        'transports': <String>[],
      });
      expect(decoded.transports, const [NotificationTransportKind.inApp]);
    });

    test('rejects unknown and duplicate transport names', () {
      expect(
        () => NotificationRoutingRule.fromJson(const {
          'transports': ['pushover', 'not_real'],
        }),
        throwsFormatException,
      );
      expect(
        () => NotificationRoutingRule.fromJson(const {
          'transports': ['discord', 'discord'],
        }),
        throwsFormatException,
      );
    });

    test('rejects invalid severity and negative/fractional limits', () {
      expect(
        () => NotificationRoutingRule.fromJson(const {
          'minSeverity': 'catastrophic',
        }),
        throwsFormatException,
      );
      expect(
        () => NotificationRoutingRule.fromJson(const {'maxPerHour': -1}),
        throwsFormatException,
      );
      expect(
        () => NotificationRoutingRule.fromJson(const {'debounceSeconds': 1.5}),
        throwsFormatException,
      );
    });
  });

  group('NotificationRoutingMatrix', () {
    test('defaults() covers every category', () {
      final matrix = NotificationRoutingMatrix.defaults();
      for (final c in NotificationCategory.values) {
        // ruleFor must always return a non-null rule with at least one transport.
        final rule = matrix.ruleFor(c);
        expect(rule.transports, isNotEmpty);
      }
    });

    test('critical categories include systemPush by default', () {
      final matrix = NotificationRoutingMatrix.defaults();
      expect(
        matrix.ruleFor(NotificationCategory.weatherUnsafe).transports,
        contains(NotificationTransportKind.systemPush),
      );
      expect(
        matrix.ruleFor(NotificationCategory.sequenceFailed).transports,
        contains(NotificationTransportKind.systemPush),
      );
      expect(
        matrix.ruleFor(NotificationCategory.transientDiscovered).transports,
        contains(NotificationTransportKind.systemPush),
      );
    });

    test('roundtrips via JSON', () {
      final matrix = NotificationRoutingMatrix.defaults().withRule(
        NotificationCategory.targetCompleted,
        const NotificationRoutingRule(
          transports: [NotificationTransportKind.pushover],
          titleTemplate: 'Done',
        ),
      );
      final decoded = NotificationRoutingMatrix.fromJson(matrix.toJson());
      expect(
        decoded.ruleFor(NotificationCategory.targetCompleted).titleTemplate,
        'Done',
      );
    });

    test('disabled flag persists through JSON', () {
      const matrix = NotificationRoutingMatrix(enabled: false);
      final decoded = NotificationRoutingMatrix.fromJson(matrix.toJson());
      expect(decoded.enabled, false);
    });
  });
}
