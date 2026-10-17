import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

class _LoadedAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

int _pushLoadAttempts = 0;

class _FailingPushConfig extends PushNotificationConfigNotifier {
  @override
  Future<PushNotificationConfig> build() async {
    _pushLoadAttempts++;
    throw StateError('push config unavailable');
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

int _unexpectedRemotePushLoads = 0;

class _CountingPushConfig extends PushNotificationConfigNotifier {
  @override
  Future<PushNotificationConfig> build() async {
    _unexpectedRemotePushLoads++;
    return const PushNotificationConfig();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('push outage isolates its controls and exposes retry',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final database = mockDatabase();
    addTearDown(database.close);
    _pushLoadAttempts = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appSettingsProvider.overrideWith(_LoadedAppSettings.new),
          pushNotificationConfigProvider.overrideWith(
            _FailingPushConfig.new,
          ),
          // The Discord section below the push block is keyring-backed; give it
          // a store so it resolves and can serve as the "the rest of the page
          // still rendered" probe.
          secretsStoreProvider.overrideWithValue(
            SecretsStore(InMemorySecureKeyValueStore()),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: NotificationSettings()),
        ),
      ),
    );
    await tester.pump();
    // Several pumps: the transport sections below the push block resolve
    // through the async keyring/DAO providers.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(find.text('Could not load push configuration'), findsOneWidget);
    // The reason is shown; the StateError's 'Bad state: ' rendering prefix is
    // not product copy and must not reach the card.
    expect(find.textContaining('push config unavailable'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Enable push to mobile'), findsNothing);
    expect(find.text('Enable notifications'), findsOneWidget);
    // The transport sections below the push block still render. (Probing the
    // section heading rather than a field label: Discord is keyring-backed, so
    // in this bare container it renders its own load-error card — which is
    // still proof that the push outage did not take the rest of the page out.)
    expect(find.text('Discord'.toUpperCase()), findsOneWidget);
    expect(_pushLoadAttempts, 1);

    // The leaf grew a precedence-disclosure section above this card, so the
    // Retry button can sit below a fixed-size test viewport.
    final retry = find.widgetWithText(SkotiqButton, 'Retry').first;
    await tester.ensureVisible(retry);
    await tester.pump();
    await tester.tap(retry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_pushLoadAttempts, 2);
    expect(find.text('Enable push to mobile'), findsNothing);
  });

  testWidgets('remote controller never edits a local push/routing copy',
      (tester) async {
    final remote = _MockNetworkBackend();
    when(() => remote.eventStream).thenAnswer((_) => const Stream.empty());
    _unexpectedRemotePushLoads = 0;

    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationSettings()),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, remote),
        ),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        pushNotificationConfigProvider.overrideWith(_CountingPushConfig.new),
        remoteHomeAssistantHostSettingsProvider.overrideWith(
          (ref) async => null,
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Configure push on the Skotiq host'), findsOneWidget);
    expect(
      find.text('Configure routing on the Skotiq host'),
      findsOneWidget,
    );
    expect(find.text('Enable push to mobile'), findsNothing);
    expect(find.text('Notification routing enabled'), findsNothing);
    expect(_unexpectedRemotePushLoads, 0);
  });
}
