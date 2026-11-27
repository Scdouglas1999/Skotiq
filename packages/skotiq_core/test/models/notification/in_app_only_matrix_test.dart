import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  final inAppOnly = NotificationRoutingMatrix.inAppOnly();
  final defaults = NotificationRoutingMatrix.defaults();

  test('every category has a rule that sends in-app only', () {
    expect(inAppOnly.enabled, isTrue);
    expect(inAppOnly.rules.keys.toSet(), NotificationCategory.values.toSet());
    for (final category in NotificationCategory.values) {
      expect(inAppOnly.rules[category]!.transports, const [
        NotificationTransportKind.inApp,
      ], reason: category.name);
    }
  });

  test('it is the defaults with the transports narrowed', () {
    for (final category in NotificationCategory.values) {
      final rule = inAppOnly.ruleFor(category);
      final base = defaults.ruleFor(category);
      expect(rule.minSeverity, base.minSeverity, reason: category.name);
      expect(rule.maxPerHour, base.maxPerHour, reason: category.name);
      expect(rule.debounceSeconds, base.debounceSeconds, reason: category.name);
    }
  });

  test('no default rule sends anywhere without the in-app notice', () {
    for (final category in NotificationCategory.values) {
      expect(
        defaults.ruleFor(category).transports,
        contains(NotificationTransportKind.inApp),
        reason: category.name,
      );
    }
  });

  test('every critical and safety category stays on', () {
    for (final category in [
      ...NotificationCategory.values.where((c) => c.isCritical),
      NotificationCategory.mountFault,
      NotificationCategory.weatherUnsafe,
      NotificationCategory.recoveryGaveUp,
    ]) {
      expect(
        inAppOnly.ruleFor(category).enabled,
        isTrue,
        reason: category.name,
      );
    }
  });

  test('the router keeps it as it is', () {
    final router = NotificationRouter(transports: const [], matrix: inAppOnly);
    expect(router.matrix, inAppOnly);
    router.updateMatrix(inAppOnly);
    expect(router.matrix, inAppOnly);
  });
}
