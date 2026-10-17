// Widget tests for [HeartbeatHealthIndicator].
//
// We render the indicator inside a minimal `MaterialApp` with a real
// `ProviderContainer` (via `ProviderScope.overrides`) and exercise
// each of the four reachable states (healthy / degraded / reconnecting
// / unknown). Color comparisons go against the same `SkotiqColors`
// instance the widget reads, so a future palette tweak doesn't make
// these tests stale.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/heartbeat_health_indicator.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  const colors = SkotiqColors.dark;
  const deviceId = 'native:zwo:0';

  Future<void> pumpIndicator(
    WidgetTester tester, {
    DateTime Function()? now,
    void Function(DeviceHeartbeatHealthNotifier)? seed,
  }) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        deviceHeartbeatHealthProvider.overrideWith(
          (ref) => DeviceHeartbeatHealthNotifier(now: now),
        ),
      ],
    );
    if (seed != null) {
      seed(container.read(deviceHeartbeatHealthProvider.notifier));
    }
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: HeartbeatHealthIndicator(
                deviceId: deviceId,
                colors: colors,
              ),
            ),
          ),
        ),
      ),
    );
    // Settle the initial pulse animation so the final dot scale = 1.0
    // and a stable Container can be located.
    await tester.pumpAndSettle();
  }

  /// Pull the rendered dot's color out of the indicator's BoxDecoration.
  Color dotColor(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(HeartbeatHealthIndicator),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    return decoration.color!;
  }

  testWidgets('renders gray when no heartbeat data is present', (tester) async {
    await pumpIndicator(tester);

    expect(dotColor(tester), colors.textMuted);

    // Tooltip message reflects "no heartbeat data" so the user knows
    // the absence is intentional, not a stuck state.
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('No heartbeat data'));
  });

  testWidgets('renders green when device is healthy', (tester) async {
    await pumpIndicator(
      tester,
      seed: (n) => n.applyStatusEvent(
        deviceId: deviceId,
        status: 'healthy',
      ),
    );

    expect(dotColor(tester), colors.success);

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Healthy'));
  });

  testWidgets('renders amber when device is degraded with reason',
      (tester) async {
    await pumpIndicator(
      tester,
      seed: (n) => n.applyStatusEvent(
        deviceId: deviceId,
        status: 'degraded',
        consecutiveFailures: 3,
        lastRttMs: 250,
      ),
    );

    expect(dotColor(tester), colors.warning);

    // The tooltip must carry the actual failure count and RTT, not a generic
    // "something went wrong".
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Degraded'));
    expect(tooltip.message, contains('3'));
    expect(tooltip.message, contains('250'));
  });

  testWidgets('renders amber with attempt counter when reconnecting',
      (tester) async {
    await pumpIndicator(
      tester,
      seed: (n) => n.applyReconnecting(
        deviceId: deviceId,
        attempt: 2,
        maxAttempts: 5,
      ),
    );

    expect(dotColor(tester), colors.warning);

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Reconnecting'));
    expect(tooltip.message, contains('attempt 2'));
  });

  testWidgets('returns to green on recovery and reports the recovery note',
      (tester) async {
    await pumpIndicator(
      tester,
      seed: (n) {
        n.applyStatusEvent(
          deviceId: deviceId,
          status: 'degraded',
          consecutiveFailures: 4,
        );
        n.applyReconnected(deviceId: deviceId, afterAttempts: 3);
      },
    );

    expect(dotColor(tester), colors.success);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Healthy'));
    expect(tooltip.message, contains('3'));
  });

  testWidgets('pulse animation replays on state transition', (tester) async {
    // Pump healthy state first.
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        deviceHeartbeatHealthProvider.overrideWith(
          (ref) => DeviceHeartbeatHealthNotifier(),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(deviceHeartbeatHealthProvider.notifier).applyStatusEvent(
          deviceId: deviceId,
          status: 'healthy',
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: HeartbeatHealthIndicator(
                deviceId: deviceId,
                colors: colors,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Capture the scale Transform after the initial animation settled
    // — it should be 1.0.
    final transformBefore =
        tester.widget<Transform>(find.byType(Transform).first);
    expect(transformBefore.transform.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

    // Fire a transition to degraded and verify the pulse re-starts
    // (mid-animation the scale > 1.0).
    container.read(deviceHeartbeatHealthProvider.notifier).applyStatusEvent(
          deviceId: deviceId,
          status: 'degraded',
          consecutiveFailures: 1,
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final transformDuring =
        tester.widget<Transform>(find.byType(Transform).first);
    expect(transformDuring.transform.getMaxScaleOnAxis(), greaterThan(1.0));

    // Drain the rest of the animation.
    await tester.pumpAndSettle();
  });
}
