// The Notifications page holds three sets of switches that each touch "a run
// finished": Skotiq's own alerts, Push to phones, and the events list under
// Where alerts go. The page has to say, in plain words, what each set does.
//
// Skotiq's own alerts are live: `NotificationService._shouldNotifyForEvent`
// refuses the whole alert for a family whose flag is off. Showing them as
// inert would drop meridian-flip alerts (that flag defaults to off) while
// refusing to let anyone turn them on, so the switches must stay enabled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';

import '../../harness/harness.dart';

Future<void> _pump(WidgetTester tester) async {
  await pumpAppScreen(
    tester,
    const NotificationSettings(),
    size: const Size(1000, 1600),
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// Scoped to Skotiq's own alerts: "Meridian flip" is also a Push to phones
/// row title, so an unscoped `find.text` matches two rows.
Finder _row(String title) => find.descendant(
      of: find.ancestor(
        of: find.text("Skotiq's own alerts".toUpperCase()),
        matching: find.byType(SettingsSection),
      ),
      matching: find.widgetWithText(SettingRow, title),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the master switch says what it covers and what it does not',
      (tester) async {
    await _pump(tester);

    expect(
      find.descendant(
        of: _row('Send these alerts'),
        matching: find.textContaining('Run events further down are not '
            'affected'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the page is written without engineering words', (tester) async {
    await _pump(tester);

    final words = RegExp(r'\b(routing|transports?|gates?|toggles?)\b',
        caseSensitive: false);
    final offending = [
      for (final widget in tester.widgetList<Text>(find.byType(Text)))
        if (widget.data case final text? when words.hasMatch(text)) text,
    ];
    expect(offending, isEmpty);
  });

  testWidgets('all three built-in event switches are operable', (tester) async {
    await _pump(tester);

    for (final title in const ['End of the night', 'Errors', 'Meridian flip']) {
      final row = _row(title);
      expect(row, findsOneWidget, reason: '$title row is missing');

      final toggle = tester.widget<SettingsSwitch>(
        find.descendant(of: row, matching: find.byType(SettingsSwitch)),
      );
      expect(
        toggle.enabled,
        isTrue,
        reason: '$title gates a live delivery path, so it must be settable',
      );
    }
  });

  testWidgets('each row says what its own event family covers', (tester) async {
    await _pump(tester);

    expect(
      find.descendant(
        of: _row('Errors'),
        matching: find.textContaining(
          'A capture that failed, or a device that would not reconnect',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('Meridian flip'),
        matching: find.textContaining(
          'When the mount starts and finishes a flip',
        ),
      ),
      findsOneWidget,
    );
  });
}
