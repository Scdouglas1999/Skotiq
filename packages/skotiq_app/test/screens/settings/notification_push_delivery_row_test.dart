// Renders the REAL notification-settings surface and asserts the
// "Push critical alerts to mobile" row reports true delivery state.
//
// Live-observed on Android (2026-07-25): the row rendered
//   "Push critical alerts to mobile"
//   "Forward critical events to paired phones (separate from per-event push
//    toggles below)"
// toggled ON, with nothing indicating this device could not receive them —
// and it could not, because `apps/mobile/android/app/google-services.json`
// does not exist so the client never registers an FCM token.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/services/push_delivery_targets_provider.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

class _LoadedAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

Future<void> _pumpWithTargets(
  WidgetTester tester,
  PushDeliveryTargets targets,
) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final database = mockDatabase();
  addTearDown(database.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        pushDeliveryTargetsProvider.overrideWith((ref) async => targets),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: NotificationSettings()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'STATE A — no registered device: the row says so and never claims '
    'delivery',
    (tester) async {
      await _pumpWithTargets(tester, PushDeliveryTargets.none);

      // The row is still there (the preference remains settable)…
      expect(find.text('Push critical alerts to mobile'), findsOneWidget);

      // …and no intent-only copy that implies delivery works.
      expect(
        find.textContaining('Forward critical events to paired phones'),
        findsNothing,
      );

      // It states the real blocker and what actually happens today.
      expect(
        find.textContaining('No device has registered for push'),
        findsOneWidget,
      );
      expect(
        find.textContaining('only appear in the app'),
        findsOneWidget,
      );
      expect(find.textContaining('Delivering to'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'STATE B — a registered device on a configured host: the row reports '
    'real delivery',
    (tester) async {
      await _pumpWithTargets(
        tester,
        const PushDeliveryTargets(
          registeredDeviceCount: 1,
          fcmTokenCount: 1,
          apnsTokenCount: 0,
          cloudDeliveryConfigured: true,
        ),
      );

      expect(find.text('Push critical alerts to mobile'), findsOneWidget);
      expect(find.text('Delivering to 1 registered device'), findsOneWidget);
      expect(
        find.textContaining('No device has registered'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a registered device with no host channel still refuses to claim '
    'delivery',
    (tester) async {
      await _pumpWithTargets(
        tester,
        const PushDeliveryTargets(
          registeredDeviceCount: 2,
          fcmTokenCount: 2,
          apnsTokenCount: 0,
          cloudDeliveryConfigured: false,
        ),
      );

      expect(find.textContaining('Delivering to'), findsNothing);
      expect(
        find.textContaining('This host has no push delivery configured'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
