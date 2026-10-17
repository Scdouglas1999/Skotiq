import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/notification/notification_template.dart';

void main() {
  group('renderNotificationTemplate', () {
    test('substitutes context values verbatim', () {
      final out = renderNotificationTemplate(
        r'Hello ${target.name}',
        const NotificationContext({'target.name': 'M42'}),
      );
      expect(out, 'Hello M42');
    });

    test('falls back to catalog example for unknown variable', () {
      // `target.alt` is in the catalog with example '42.7'; if the
      // context doesn't provide it we should still render the example
      // rather than `${target.alt?}`.
      final out = renderNotificationTemplate(
        r'Altitude: ${target.alt}',
        const NotificationContext({}),
      );
      expect(out, contains('Altitude:'));
      expect(out, isNot(contains('?}')));
    });

    test(r'renders ${name?} for variables not in catalog or context', () {
      final out = renderNotificationTemplate(
        r'Unknown ${foo.bar}',
        const NotificationContext({}),
      );
      expect(out, 'Unknown \${foo.bar?}');
    });

    test('applies fixed-point format spec', () {
      final out = renderNotificationTemplate(
        r'${moon.phase:.2f}',
        const NotificationContext({'moon.phase': '0.4275'}),
      );
      expect(out, '0.43');
    });

    test('applies zero-pad format spec', () {
      final out = renderNotificationTemplate(
        r'${frame:04}',
        const NotificationContext({'frame': '7'}),
      );
      expect(out, '0007');
    });

    test(r'$$ escapes the placeholder opener', () {
      final out = renderNotificationTemplate(
        r'$${literal}',
        const NotificationContext({}),
      );
      expect(out, r'${literal}');
    });

    test('unterminated placeholder is rendered verbatim', () {
      final out = renderNotificationTemplate(
        r'Broken ${target.name',
        const NotificationContext({}),
      );
      expect(out, startsWith('Broken'));
    });

    test('time.now is populated by default when not in context', () {
      final out = renderNotificationTemplate(
        r'@${time.now}',
        const NotificationContext({}),
      );
      expect(out, startsWith('@'));
      expect(out.length, greaterThan(5));
      // Must not have been left as the literal placeholder.
      expect(out, isNot(contains('time.now?}')));
    });
  });
}
