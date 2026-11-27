// The device and centering notices are routing rows: Settings › Notifications
// lists each one, and its switch is saved.
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
  testWidgets(
      'Settings › Notifications lists the device notices and saves '
      'their switch', (tester) async {
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

    for (final category in const [
      NotificationCategory.mountMoved,
      NotificationCategory.targetCentered,
      NotificationCategory.focusOffsetFailed,
      NotificationCategory.deviceAnsweredLate,
      NotificationCategory.checkpointFailed,
    ]) {
      await tester.scrollUntilVisible(
        find.text(category.label),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(_row(category.label), findsOneWidget, reason: category.label);
    }

    final row = _row(NotificationCategory.mountMoved.label);
    await tester.scrollUntilVisible(
      find.text(NotificationCategory.mountMoved.label),
      -300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.descendant(of: row, matching: find.text('Edit')));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
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
    expect(matrix.ruleFor(NotificationCategory.mountMoved).enabled, isFalse);
    expect(
      find.descendant(
          of: _row(NotificationCategory.mountMoved.label),
          matching: find.text('Not sent')),
      findsOneWidget,
    );
  });
}
