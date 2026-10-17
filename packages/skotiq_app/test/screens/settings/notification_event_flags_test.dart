// The three built-in event switches gate real delivery, so Settings has to
// both say so and let the operator set them.
//
// `NotificationService._shouldNotifyForEvent` returns
// `settings.notifyOnSequenceComplete` / `notifyOnError` / `notifyOnMeridianFlip`
// and `notify()` aborts the entire dispatch on a false — no alert sound, no
// router forward, no Discord, no Pushover. `notifyOnMeridianFlip` ships as
// `false`, so out of the box the flip monitor's alerts are dropped. The leaf
// previously rendered all three DISABLED under "Legacy event flags (not wired
// up)", which meant the one switch that was actively silencing an event family
// was also the one the operator could not turn on.
//
// These tests pin the two halves of the fix: the switches write through to the
// settings store and survive a reload, and the meridian row states its
// off-by-default status in words instead of just showing a grey toggle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

/// A [SettingsDao] backed by a plain map, so a test can assert what the UI
/// actually persisted and then reload the notifier from that same store.
///
/// [loads] counts `getAllSettings` calls — the notifier's only read path — so a
/// reload assertion cannot pass on a value that merely stayed in memory.
class _Store {
  _Store() {
    dao = _MockSettingsDao();
    when(dao.getAllSettings).thenAnswer((_) async {
      loads++;
      return Map.of(values);
    });
    when(() => dao.getSetting(any())).thenAnswer(
      (i) async => values[i.positionalArguments[0] as String],
    );
    when(() => dao.setSetting(any(), any())).thenAnswer((i) async {
      values[i.positionalArguments[0] as String] =
          i.positionalArguments[1] as String;
    });
    when(() => dao.setSettings(any())).thenAnswer((i) async {
      values.addAll(i.positionalArguments[0] as Map<String, String>);
    });
  }

  final Map<String, String> values = <String, String>{};
  late final _MockSettingsDao dao;
  int loads = 0;

  String? operator [](String key) => values[key];
}

/// Pump until [ready] holds, or fail naming what never arrived.
///
/// The leaf renders a loading state until `appSettingsProvider` resolves, and
/// that resolution rides real futures rather than fake time, so a fixed pump
/// count asserts against whichever half of the load happened to land. Each
/// step both advances fake time (the switch write is a debounce timer) and
/// yields an event-loop turn (the settings read is a future).
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration step = const Duration(milliseconds: 50),
  int maxSteps = 200,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    if (ready()) return;
    await tester.pump(step);
  }
  if (!ready()) {
    fail('timed out waiting for $reason');
  }
}

Future<HarnessHandle> _pump(WidgetTester tester, _Store store) async {
  final handle = await pumpAppScreen(
    tester,
    const NotificationSettings(),
    size: const Size(1000, 1600),
    settle: false,
    extraOverrides: [settingsDaoProvider.overrideWithValue(store.dao)],
  );
  await _pumpUntil(
    tester,
    () => _builtInSection().evaluate().isNotEmpty,
    reason: 'the built-in event alerts section to render',
  );
  return handle;
}

/// Scoped to the built-in section on purpose: "Meridian flip" is also a Push
/// to Mobile row title, and an unscoped `find.text` matches both.
Finder _builtInSection() => find.ancestor(
      of: find.text('Built-in event alerts'.toUpperCase()),
      matching: find.byType(SettingsSection),
    );

Finder _row(String rowTitle) => find.descendant(
      of: _builtInSection(),
      matching: find.widgetWithText(SettingRow, rowTitle),
    );

Finder _switchIn(String rowTitle) =>
    find.descendant(of: _row(rowTitle), matching: find.byType(SkotiqSwitch));

/// Tap a row's switch and return once [settingKey] has actually changed in
/// [store] — the 300ms write debounce in [SettingsSwitch] and the store write
/// it schedules land on separate turns, and only the second one is what the
/// persistence assertions are about.
Future<void> _toggle(
  WidgetTester tester,
  _Store store,
  String rowTitle,
  String settingKey,
) async {
  final before = store[settingKey];
  final target = _switchIn(rowTitle);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _pumpUntil(
    tester,
    () => store[settingKey] != before,
    reason: 'the $rowTitle switch to write $settingKey',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('subtitle copy', () {
    test('an enabled family names the transports it reaches', () {
      final subtitle = builtInEventAlertSubtitle(
        'Gates the built-in error alert.',
        enabled: true,
      );
      expect(subtitle, contains('Gates the built-in error alert.'));
      expect(subtitle, contains('alert sound'));
      expect(subtitle, contains('Discord/Pushover webhook'));
      // The claim that started this: it must never come back.
      expect(subtitle, isNot(contains('no longer sends anything')));
    });

    test('a disabled family says nothing is sent, not that it is unwired', () {
      final subtitle = builtInEventAlertSubtitle(
        'Gates the built-in error alert.',
        enabled: false,
      );
      expect(subtitle, contains('this event family sends nothing'));
      expect(subtitle, isNot(contains('Superseded')));
    });

    test('an off-by-default family says the default is ours, not the user\'s',
        () {
      final subtitle = builtInEventAlertSubtitle(
        'Gates the built-in meridian-flip alert.',
        enabled: false,
        offByDefault: true,
      );
      expect(subtitle, contains('off is the shipped default'));
      expect(subtitle, contains('until you turn this on'));
    });
  });

  group('shipped defaults', () {
    test('meridian flip is the one built-in alert that starts off', () {
      const shipped = AppSettingsState();
      expect(shipped.notifyOnSequenceComplete, isTrue);
      expect(shipped.notifyOnError, isTrue);
      expect(
        shipped.notifyOnMeridianFlip,
        isFalse,
        reason: 'if this ever flips to true the meridian row must stop '
            'telling the operator it is off by default',
      );
    });
  });

  testWidgets('the meridian row states its off-by-default status in words', (
    tester,
  ) async {
    await _pump(tester, _Store());

    expect(
      find.descendant(
        of: _row('Meridian flip'),
        matching: find.textContaining('off is the shipped default'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<SkotiqSwitch>(_switchIn('Meridian flip')).value,
      isFalse,
    );
  });

  testWidgets('turning meridian-flip alerts on persists and survives a reload',
      (tester) async {
    final store = _Store();
    final handle = await _pump(tester, store);

    await _toggle(tester, store, 'Meridian flip', 'notify_on_meridian_flip');

    expect(
      store['notify_on_meridian_flip'],
      'true',
      reason: 'the switch must reach the settings store, not just the UI',
    );
    expect(
      handle.container.read(appSettingsProvider).value!.notifyOnMeridianFlip,
      isTrue,
    );

    // Rebuild the notifier from the store the UI just wrote: the value has to
    // come back through the stored-map mapping, not only live in memory.
    final loadsBefore = store.loads;
    handle.container.invalidate(appSettingsProvider);
    await _pumpUntil(
      tester,
      () => !handle.container.read(appSettingsProvider).isLoading,
      reason: 'the settings notifier to finish rebuilding from the store',
    );
    await tester.pump();
    expect(
      store.loads,
      greaterThan(loadsBefore),
      reason: 'the reload must actually re-read the store, or the assertion '
          'below proves nothing about persistence',
    );
    expect(
      handle.container.read(appSettingsProvider).value!.notifyOnMeridianFlip,
      isTrue,
    );

    // …and the row now reports the on-state copy.
    expect(
      find.descendant(
        of: _row('Meridian flip'),
        matching: find.textContaining('Delivered by the alert sound'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('silencing the error family writes false, not nothing', (
    tester,
  ) async {
    final store = _Store();
    final handle = await _pump(tester, store);

    expect(
      tester.widget<SkotiqSwitch>(_switchIn('Errors')).value,
      isTrue,
      reason: 'error alerts ship on',
    );

    await _toggle(tester, store, 'Errors', 'notify_on_error');

    expect(store['notify_on_error'], 'false');
    expect(
      handle.container.read(appSettingsProvider).value!.notifyOnError,
      isFalse,
    );
  });

  testWidgets('the sequence-complete switch is settable too', (tester) async {
    final store = _Store();
    final handle = await _pump(tester, store);

    await _toggle(
      tester,
      store,
      'Sequence complete',
      'notify_on_sequence_complete',
    );

    expect(store['notify_on_sequence_complete'], 'false');
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .notifyOnSequenceComplete,
      isFalse,
    );
  });
}
