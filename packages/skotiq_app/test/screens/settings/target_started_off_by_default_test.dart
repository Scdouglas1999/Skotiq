// "Target started" is off by default (9.3.4), and the release notes send the
// operator to Settings › Notifications to turn it back on. That page lists it
// as not sent, and its editor turns it on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../harness/harness.dart';

Finder _row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(SettingRow),
    );

void main() {
  testWidgets('Settings › Notifications lists Target started as not sent',
      (tester) async {
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);

    final handle = await pumpAppScreen(
      tester,
      SettingsScreen(
          initialSection: SettingsSectionId.resolve('notifications')),
      size: const Size(1280, 2400),
      settle: false,
      extraOverrides: [
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );
    await handle.container.read(notificationRoutingMatrixProvider.future);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Notifications'), findsWidgets);
    final row = _row('Target started');
    await tester.scrollUntilVisible(
      find.text('Target started'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Not sent')),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: row, matching: find.text('Edit')));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(
      find.descendant(of: dialog, matching: find.text('Target started')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('Send this event')),
    );
    await tester.pump();
    await tester.tap(find.descendant(of: dialog, matching: find.text('Save')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    final matrix =
        await handle.container.read(notificationRoutingMatrixProvider.future);
    expect(matrix.ruleFor(NotificationCategory.targetStarted).enabled, isTrue);
    expect(
      find.descendant(
          of: _row('Target started'), matching: find.text('Not sent')),
      findsNothing,
    );
  });
}
