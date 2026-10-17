// The Notifications leaf ships three overlapping systems at once and offers
// three near-identically named controls for "a sequence finished" — Built-in
// event alerts › Sequence complete, Push to Mobile › Sequence completed, and
// Per-event routing › Sequence Completed. The page has to say which one decides
// whether the operator's phone buzzes.
//
// Saying it wrong is worse than saying nothing. The three built-in switches are
// live gates: `NotificationService._shouldNotifyForEvent` aborts the whole
// dispatch for an event family whose flag is off. Presenting them as inert
// decoration — disabled, captioned "not read by any delivery path" — would drop
// meridian-flip alerts (that flag defaults to false) while refusing to let
// anyone turn them on. So the disclosure must stay accurate AND the switches
// must stay enabled.

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

/// Scoped to the built-in section: "Meridian flip" is also a Push to Mobile
/// row title, so an unscoped `find.text` matches two rows.
Finder _row(String title) => find.descendant(
      of: find.ancestor(
        of: find.text('Built-in event alerts'.toUpperCase()),
        matching: find.byType(SettingsSection),
      ),
      matching: find.widgetWithText(SettingRow, title),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the leaf says which system actually delivers', (tester) async {
    await _pump(tester);

    expect(
      find.textContaining('Per-event routing (Settings → Notification Routing) '
          'maps each event to its transports and is what actually delivers'),
      findsOneWidget,
    );
  });

  testWidgets('it no longer calls the built-in switches unread', (
    tester,
  ) async {
    await _pump(tester);

    // The exact claim that was false. `_shouldNotifyForEvent` reads all three.
    expect(find.textContaining('not read by any delivery path'), findsNothing);
    expect(find.textContaining('no longer sends anything'), findsNothing);
    expect(find.text('Legacy event flags (not wired up)'), findsNothing);
    // Uppercase: the section label is an eyebrow (06 §Settings).
    expect(
      find.text('Built-in event alerts'.toUpperCase()),
      findsOneWidget,
    );
  });

  testWidgets('all three built-in event switches are operable', (tester) async {
    await _pump(tester);

    for (final title in const [
      'Sequence complete',
      'Errors',
      'Meridian flip'
    ]) {
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
          'capture failures and device-reconnect failures',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('Meridian flip'),
        matching: find.textContaining(
          'raised when the flip monitor starts and finishes a flip',
        ),
      ),
      findsOneWidget,
    );
  });
}
