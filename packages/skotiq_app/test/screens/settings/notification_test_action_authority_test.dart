import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _LoadedAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        discordWebhook: 'https://discord.example/test',
      );
}

class _MockNotificationService extends Mock implements NotificationService {}

/// The legacy `app_settings`-backed Discord row is a remote-controller-only
/// surface now (locally the keyring-backed section owns Discord), so this
/// authority test drives it through a [NetworkBackend] stand-in.
class _MockNetworkBackend extends Mock implements NetworkBackend {}

_MockNetworkBackend _networkBackend() {
  final backend = _MockNetworkBackend();
  final events = StreamController<SkotiqEvent>.broadcast();
  final polar = StreamController<Map<String, dynamic>>.broadcast();
  when(() => backend.eventStream).thenAnswer((_) => events.stream);
  when(() => backend.polarAlignmentEvents).thenAnswer((_) => polar.stream);
  when(() => backend.dispatchPluginNodesLocally).thenReturn(false);
  when(() => backend.dispose()).thenAnswer((_) {
    events.close();
    polar.close();
  });
  return backend;
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Finder _discordTestButton() {
  final row = find.ancestor(
    of: find.text('Test Discord'),
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
    'notification tests are single-flight and discard an old-rig result',
    (tester) async {
      final hostA = _networkBackend();
      final hostB = _networkBackend();
      addTearDown(hostA.dispose);
      addTearDown(hostB.dispose);
      final result = Completer<bool>();
      final service = _MockNotificationService();
      when(
        () => service.testDiscordWebhook('https://discord.example/test'),
      ).thenAnswer((_) => result.future);
      late _SwappableBackendNotifier backendNotifier;

      await pumpAppScreen(
        tester,
        const NotificationSettings(),
        size: const Size(1200, 1200),
        settle: false,
        extraOverrides: [
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
          appSettingsProvider.overrideWith(_LoadedAppSettings.new),
          notificationServiceProvider.overrideWithValue(service),
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(_discordTestButton());
      await tester.pump();
      await tester.tap(_discordTestButton());
      await tester.tap(_discordTestButton());
      verify(
        () => service.testDiscordWebhook('https://discord.example/test'),
      ).called(1);
      await tester.pump();

      var button = tester.widget<SkotiqButton>(_discordTestButton());
      expect(button.isLoading, isTrue);
      expect(button.onPressed, isNull);

      backendNotifier.switchTo(hostB);
      await tester.pump();
      button = tester.widget<SkotiqButton>(_discordTestButton());
      expect(button.isLoading, isFalse);
      expect(button.onPressed, isNotNull);

      result.complete(true);
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Discord test notification sent successfully!'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
