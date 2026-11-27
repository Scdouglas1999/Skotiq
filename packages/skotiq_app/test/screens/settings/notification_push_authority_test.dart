import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
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

/// The host's key/value store as a linked client reaches it.
class _HostStore extends Mock implements HostRigSettings {
  _HostStore({this.adminAccess = true});

  /// Whether the link has admin access, as the host reports it.
  final bool adminAccess;
  final Map<String, String> rows = {};

  @override
  Future<HostSettingsRows> getSettingsStore() async =>
      HostSettingsRows(Map.of(rows), adminAccess: adminAccess);

  @override
  Future<void> updateSettingsStore(
    Map<String, String> settings, {
    List<String> remove = const [],
  }) async {
    rows.addAll(settings);
  }
}

class _StubPushConfig extends PushNotificationConfigNotifier {
  @override
  Future<PushNotificationConfig> build() async =>
      const PushNotificationConfig();
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

    expect(find.text('Could not load the phone settings'), findsOneWidget);
    // The reason is shown; the StateError's 'Bad state: ' rendering prefix is
    // not product copy and must not reach the card.
    expect(find.textContaining('push config unavailable'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Push to phones'), findsNothing);
    expect(find.text('Send these alerts'), findsOneWidget);
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
    expect(find.text('Push to phones'), findsNothing);
  });

  // The alert routes keep a local copy only on the host. A linked controller
  // edits phone pushes on the host (the next test); its routing section says
  // where the routes are set up instead of editing a copy of its own.
  testWidgets('remote controller never edits a local routing copy',
      (tester) async {
    final remote = _MockNetworkBackend();
    when(() => remote.eventStream).thenAnswer((_) => const Stream.empty());

    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationSettings()),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, remote),
        ),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        pushNotificationConfigProvider.overrideWith(_StubPushConfig.new),
        remoteHomeAssistantHostSettingsProvider.overrideWith(
          (ref) async => null,
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Set up on the imaging computer'),
      findsOneWidget,
    );
    expect(find.text('Send alerts'), findsNothing);
    // The line does not send the operator away for what this page edits.
    expect(
      find.textContaining('Discord and Pushover are above'),
      findsOneWidget,
    );
  });

  // A headless host has no screen: a linked phone edits which events the host
  // pushes to phones, in the host's own store.
  testWidgets('an admin-linked phone edits the host push config on the host',
      (tester) async {
    final remote = _MockNetworkBackend();
    when(() => remote.eventStream).thenAnswer((_) => const Stream.empty());
    final host = _HostStore();
    final store = HostSettingsStore(host, () => const Stream.empty());
    addTearDown(store.dispose);

    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationSettings()),
      settle: false,
      extraOverrides: [
        launchRoleProvider.overrideWithValue(LaunchRole.mobile),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, remote),
        ),
        hostSettingsStoreProvider.overrideWithValue(store),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        remoteHomeAssistantHostSettingsProvider.overrideWith(
          (ref) async => null,
        ),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Set on the imaging computer'), findsNothing);
    final guiding = find.ancestor(
      of: find.text('Guiding lost'),
      matching: find.byType(SettingRow),
    );
    expect(guiding, findsOneWidget);
    expect(find.text('Send a test'), findsNothing,
        reason: 'the host has no route that sends a test push');

    final toggle = find.descendant(
      of: guiding,
      matching: find.byType(SettingsSwitch),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump(SettingsSwitch.writeDelay);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final written = jsonDecode(host.rows['push_notification_config']!)
        as Map<String, dynamic>;
    expect(written['notifyGuidingLost'], isFalse);
    expect(
      await handle.database.settingsDao.getSetting('push_notification_config'),
      isNull,
      reason: 'nothing is saved in the phone database',
    );
  });

  // A linked client's store write makes the host reload its push config. The
  // switches stay on screen while it reloads, so a toggle the host's own user
  // just made is still written.
  testWidgets('a reload under the page keeps the switches and their writes',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationSettings()),
      settle: false,
      extraOverrides: [
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final guiding = find.ancestor(
      of: find.text('Guiding lost'),
      matching: find.byType(SettingRow),
    );
    final toggle = find.descendant(
      of: guiding,
      matching: find.byType(SettingsSwitch),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();

    handle.container.read(settingsStoreRevisionProvider.notifier).state++;
    await tester.pump();
    expect(find.text('Guiding lost'), findsOneWidget);

    await tester.pump(SettingsSwitch.writeDelay);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final stored = await handle.database.settingsDao.getSetting(
      'push_notification_config',
    );
    expect(stored, isNotNull);
    expect(
      (jsonDecode(stored!) as Map<String, dynamic>)['notifyGuidingLost'],
      isFalse,
    );
  });

  // Which events reach every phone is the host's, like its other shared
  // settings: a link without admin access sees them and the reason, and
  // cannot change them.
  testWidgets('a control-scope phone sees the host push config read-only',
      (tester) async {
    final remote = _MockNetworkBackend();
    when(() => remote.eventStream).thenAnswer((_) => const Stream.empty());
    final host = _HostStore(adminAccess: false);
    final store = HostSettingsStore(host, () => const Stream.empty());
    addTearDown(store.dispose);

    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationSettings()),
      settle: false,
      extraOverrides: [
        launchRoleProvider.overrideWithValue(LaunchRole.mobile),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, remote),
        ),
        hostSettingsStoreProvider.overrideWithValue(store),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        remoteHomeAssistantHostSettingsProvider.overrideWith(
          (ref) async => null,
        ),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Guiding lost'), findsOneWidget);
    expect(
      find.textContaining('Which events reach every phone is changed on the '
          'imaging computer'),
      findsOneWidget,
    );
    final guiding = find.ancestor(
      of: find.text('Guiding lost'),
      matching: find.byType(SettingRow),
    );
    final toggle = find.descendant(
      of: guiding,
      matching: find.byType(SettingsSwitch),
    );
    expect(tester.widget<SettingsSwitch>(toggle).enabled, isFalse);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle, warnIfMissed: false);
    await tester.pump(SettingsSwitch.writeDelay);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(host.rows['push_notification_config'], isNull);
  });
}
