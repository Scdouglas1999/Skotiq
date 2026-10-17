// One failed connect of the built-in guider raises FOUR statements of one
// refusal — the same "Guider Error … requires an active profile with a guide
// focal length" toast TWICE (Dart connect path via ErrorService, plus the
// backend's error event via event_provider), an "Equipment disconnected" toast
// for a device that never connected, and the Connection help dialog behind all
// three.
//
// The overlay is the one place every producer converges, so that is where the
// repetition is collapsed. These tests reproduce the exact double toast.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/notification_toast_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _guiderRefusal =
    'Built-in guider requires an active profile with a guide focal length';

Future<void> _pumpOverlay(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: Stack(children: [NotificationToastOverlay()]),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two producers of one refusal render as one toast', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(uiNotificationProvider.notifier);

    // The real sequence: the identical toast twice, then the (different)
    // disconnect toast.
    notifier.showError(
      _guiderRefusal,
      title: 'Guider Error',
      duration: const Duration(minutes: 1),
    );
    notifier.showError(
      _guiderRefusal,
      title: 'Guider Error',
      duration: const Duration(minutes: 1),
    );
    notifier.showError(
      'Guider Built-in Multi-Star Guider disconnected.',
      title: 'Equipment disconnected',
      duration: const Duration(minutes: 1),
    );

    await _pumpOverlay(tester, container);

    // One row for the refusal, not two.
    expect(find.text(_guiderRefusal), findsOneWidget);
    // And it says it happened twice rather than hiding the repeat.
    expect(find.text('Guider Error (x2)'), findsOneWidget);
    expect(find.text('Guider Error'), findsNothing);
    // The genuinely different toast is still its own row.
    expect(find.text('Equipment disconnected'), findsOneWidget);
  });

  testWidgets('dismissing a collapsed toast retires every copy', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(uiNotificationProvider.notifier);
    for (var i = 0; i < 3; i++) {
      notifier.showError(
        _guiderRefusal,
        title: 'Guider Error',
        duration: const Duration(minutes: 1),
      );
    }

    await _pumpOverlay(tester, container);
    expect(find.text('Guider Error (x3)'), findsOneWidget);

    await tester.tap(find.text(_guiderRefusal));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // If only the rendered copy were dismissed, its twins would pop straight
    // back up as a "(x2)" toast.
    expect(container.read(uiNotificationProvider), isEmpty);
    expect(find.text(_guiderRefusal), findsNothing);
  });

  // Neither of the two obvious places collapses this pair. The
  // NotificationRouter's normalized-key dedupe never sees these toasts (the
  // Dart connect path calls `ErrorService.log`, the backend event path calls
  // `errorNotificationBridgeProvider`, and BOTH call
  // `UiNotificationNotifier.showError` directly), and a collapse keyed on the
  // EXACT rendered strings is defeated by one character — a trailing full stop.
  //
  // The trap is the timing: a screenshot 3 s after the click shows only ONE card
  // because the second producer lands between 3 s and 5 s. So this raises the
  // second copy at +4 s, at the production `showError` duration rather than a
  // convenient one.
  testWidgets('the repeated-error pair, four seconds apart, is one toast', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(uiNotificationProvider.notifier);

    // Verbatim from waveG-01/02/03: the two strings differ ONLY by the full
    // stop the second producer appends.
    notifier.showError(_guiderRefusal, title: 'Guider Error');
    await _pumpOverlay(tester, container);
    expect(find.text(_guiderRefusal), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    notifier.showError('$_guiderRefusal.', title: 'Guider Error');
    await tester.pump();

    expect(
      find.textContaining('requires an active profile with a guide focal '
          'length'),
      findsOneWidget,
      reason: 'one refusal, one card — a trailing full stop is not a second '
          'thing that happened',
    );
    expect(find.text('Guider Error (x2)'), findsOneWidget);

    // The older copy's own timer must not retire the group out from under the
    // newer one: at +9 s the first notification's 8 s duration has elapsed, and
    // the card the operator is reading is the one raised at +4 s.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Guider Error (x2)'), findsOneWidget);

    // ...and the whole group goes together once the NEWEST member expires.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('guide focal length'), findsNothing);
    expect(container.read(uiNotificationProvider), isEmpty);
  });

  testWidgets('a question and a statement stay two notifications', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(uiNotificationProvider.notifier);
    notifier.showWarning('Park the mount',
        title: 'Mount', duration: const Duration(minutes: 1));
    notifier.showWarning('Park the mount?',
        title: 'Mount', duration: const Duration(minutes: 1));

    await _pumpOverlay(tester, container);

    expect(find.text('Park the mount'), findsOneWidget);
    expect(find.text('Park the mount?'), findsOneWidget);
  });

  testWidgets('distinct notifications are never merged', (tester) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(uiNotificationProvider.notifier);
    notifier.showError('Mount disconnected.',
        title: 'Mount Error', duration: const Duration(minutes: 1));
    notifier.showError('Focuser disconnected.',
        title: 'Focuser Error', duration: const Duration(minutes: 1));

    await _pumpOverlay(tester, container);

    expect(find.text('Mount Error'), findsOneWidget);
    expect(find.text('Focuser Error'), findsOneWidget);
  });
}
