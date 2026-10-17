import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_routing_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

int _routingLoadAttempts = 0;

class _FailingRoutingMatrixNotifier extends RoutingMatrixNotifier {
  @override
  Future<NotificationRoutingMatrix> build() async {
    _routingLoadAttempts++;
    throw StateError('routing database unavailable');
  }
}

Finder _fieldInRow(String title) {
  final row = find.ancestor(
    of: find.text(title),
    matching: find.byType(SettingRow),
  );
  return find.descendant(of: row, matching: find.byType(TextField));
}

Finder _buttonInRow(String title, String label) {
  final row = find.ancestor(
    of: find.text(title),
    matching: find.byType(SettingRow),
  );
  return find.descendant(of: row, matching: find.text(label));
}

Future<HarnessHandle> _pump(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: NotificationRoutingSettings()),
    extraOverrides: [
      secretsStoreProvider.overrideWithValue(
        SecretsStore(InMemorySecureKeyValueStore()),
      ),
    ],
    settle: false,
  );
  await Future.wait([
    handle.container.read(notificationRoutingMatrixProvider.future),
    handle.container.read(emailTransportConfigProvider.future),
    handle.container.read(webhookTransportConfigProvider.future),
    handle.container.read(pushoverTransportConfigProvider.future),
    handle.container.read(telegramTransportConfigProvider.future),
    handle.container.read(discordTransportConfigProvider.future),
    handle.container.read(mqttTransportConfigProvider.future),
  ]);
  await tester.pump();
  return handle;
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _tapButtonInRow(
  WidgetTester tester,
  String title,
  String label,
) async {
  final button = _buttonInRow(title, label);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.scrollUntilVisible(
    button,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(button);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('routing outage hides controls and exposes a real retry',
      (tester) async {
    _routingLoadAttempts = 0;
    final handle = await pumpAppScreen(
      tester,
      const NotificationRoutingSettings(),
      extraOverrides: [
        notificationRoutingMatrixProvider.overrideWith(
          _FailingRoutingMatrixNotifier.new,
        ),
      ],
      settle: false,
    );
    addTearDown(handle.container.dispose);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Could not load the notification routing matrix.'),
      findsOneWidget,
    );
    // The reason reaches the operator; the StateError rendering prefix does
    // not — it is a diagnostic, not copy.
    expect(
      find.textContaining('routing database unavailable'),
      findsOneWidget,
    );
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Notification routing enabled'), findsNothing);
    expect(_routingLoadAttempts, 1);

    await tester.tap(find.text('Retry routing settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_routingLoadAttempts, 2);
    expect(find.text('Notification routing enabled'), findsNothing);
  });

  testWidgets('SMTP rejects an invalid port without overwriting saved config',
      (tester) async {
    final handle = await _pump(tester);
    final before = handle.container.read(emailTransportConfigProvider).value!;

    await tester.enterText(_fieldInRow('SMTP port'), '70000');
    await _tapButtonInRow(tester, 'Save SMTP settings', 'Save');
    await _pumpFrames(tester);

    final after = handle.container.read(emailTransportConfigProvider).value!;
    expect(after, before);
    expect(find.text('Enter a valid port (1-65535).'), findsOneWidget);
  });

  testWidgets(
      'SMTP persists the complete on-screen draft before reporting success',
      (tester) async {
    final handle = await _pump(tester);

    await tester.enterText(_fieldInRow('SMTP host'), 'smtp.example.com');
    await tester.enterText(_fieldInRow('SMTP port'), '2525');
    await tester.enterText(_fieldInRow('From address'), 'night@example.com');
    await tester.enterText(_fieldInRow('To address'), 'operator@example.com');
    await _tapButtonInRow(tester, 'Save SMTP settings', 'Save');
    await _pumpFrames(tester);

    final saved = handle.container.read(emailTransportConfigProvider).value!;
    expect(saved.smtpHost, 'smtp.example.com');
    expect(saved.smtpPort, 2525);
    expect(saved.fromAddress, 'night@example.com');
    expect(saved.toAddress, 'operator@example.com');
    expect(find.text('Email config saved'), findsOneWidget);
  });

  testWidgets('webhook malformed header is visible and does not persist',
      (tester) async {
    final handle = await _pump(tester);
    final before = handle.container.read(webhookTransportConfigProvider).value!;

    await tester.enterText(
      _fieldInRow('URL'),
      'https://example.com/skotiq',
    );
    await tester.enterText(_fieldInRow('Headers'), 'missing-colon');
    await _tapButtonInRow(tester, 'Save webhook config', 'Save');
    await _pumpFrames(tester);

    final after = handle.container.read(webhookTransportConfigProvider).value!;
    expect(after, before);
    expect(
      find.text('Header line 1 must be in "Name: value" form.'),
      findsOneWidget,
    );
  });

  testWidgets('stored SMTP password can be explicitly cleared', (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    final secrets = SecretsStore(InMemorySecureKeyValueStore());
    await secrets.write(SecretField.emailPassword, 'old-password');
    await database.settingsDao.setSetting(
      'notification_secrets_migrated_v2',
      'true',
    );
    await database.settingsDao.setSetting(
      'notification_transport_email',
      jsonEncode(const EmailTransportConfig().toJson()),
    );

    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationRoutingSettings()),
      database: database,
      extraOverrides: [secretsStoreProvider.overrideWithValue(secrets)],
      settle: false,
    );
    await handle.container.read(emailTransportConfigProvider.future);
    await tester.pump();

    await _tapButtonInRow(tester, 'Password', 'Clear');
    await _pumpFrames(tester);
    await _tapButtonInRow(tester, 'Save SMTP settings', 'Save');
    await _pumpFrames(tester);

    expect(await secrets.read(SecretField.emailPassword), isEmpty);
    expect(
      handle.container.read(emailTransportConfigProvider).value!.password,
      isEmpty,
    );
  });
}
