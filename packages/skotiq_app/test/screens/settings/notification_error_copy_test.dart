// Settings → Notifications must not ship Dart exception boilerplate as copy.
//
// `sendTestNotification()` reports both of its refusals with a `StateError`,
// whose `toString()` is "Bad state: <message>". Interpolating the error object
// into the snackbar put that prefix in front of otherwise-good, actionable
// copy the operator reads when push has nowhere to go.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_app/utils/user_facing_error.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _LoadedAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _EnabledPushConfig extends PushNotificationConfigNotifier {
  @override
  Future<PushNotificationConfig> build() async =>
      const PushNotificationConfig(enabled: true);
}

class _MockPushService extends Mock implements PushNotificationService {}

Finder _pushTestButton() {
  final row = find.ancestor(
    of: find.text('Test push notification'),
    matching: find.byType(SettingRow),
  );
  return find.descendant(
    of: row,
    matching: find.widgetWithText(SkotiqButton, 'Test'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a refused push test reports the reason without the StateError prefix',
    (tester) async {
      const reason =
          'No push transport is listening. Start remote access before testing.';
      final service = _MockPushService();
      when(service.sendTestNotification).thenThrow(StateError(reason));

      await pumpAppScreen(
        tester,
        const SingleChildScrollView(child: NotificationSettings()),
        size: const Size(1200, 1600),
        settle: false,
        extraOverrides: [
          appSettingsProvider.overrideWith(_LoadedAppSettings.new),
          pushNotificationConfigProvider.overrideWith(_EnabledPushConfig.new),
          pushNotificationServiceProvider.overrideWithValue(service),
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(_pushTestButton());
      await tester.pump();
      await tester.tap(_pushTestButton());
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Failed to send test notification: $reason'),
        findsOneWidget,
      );
      expect(find.textContaining('Bad state'), findsNothing);
    },
  );

  group('userFacingError', () {
    test('unwraps the message authored on each built-in error type', () {
      expect(userFacingError(StateError('no transport')), 'no transport');
      expect(
        userFacingError(UnsupportedError('remote hosts cannot browse')),
        'remote hosts cannot browse',
      );
      expect(userFacingError(Exception('write failed')), 'write failed');
      expect(
        userFacingError(const FormatException('not a number')),
        'not a number',
      );
      expect(userFacingError(ArgumentError('port required')), 'port required');
    });

    test('keeps detail it cannot safely separate from the message', () {
      // ArgumentError.value carries the offending name/value in toString()
      // alone — collapsing to `message` would drop both.
      expect(
        userFacingError(ArgumentError.value(-1, 'port', 'must be positive')),
        contains('port'),
      );
      // An unrecognised error type is passed through verbatim rather than
      // reduced to something lossy.
      expect(
          userFacingError(_OpaqueFailure()), 'host unreachable after 3 tries');
      expect(userFacingError(null), 'Unknown error');
    });
  });
}

class _OpaqueFailure {
  @override
  String toString() => 'host unreachable after 3 tries';
}
