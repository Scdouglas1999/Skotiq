// The dither and settle settings are edited in one place, GuideSettleSettings,
// on the Guiding screen and in Imaging's guiding panel. It shows the stored
// values, holds new ones to the settings table's bounds and follows a save
// made elsewhere.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/screens/guiding/widgets/guide_settle_settings.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

// Seed value the overridden settings notifier reports; each test sets it before
// pumping. Tests run sequentially so a shared top-level is safe here.
AppSettingsState _seed = const AppSettingsState();

class _SeedSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => _seed;
}

int _settingsLoadAttempts = 0;

class _FailingSettingsLoad extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    _settingsLoadAttempts++;
    throw StateError('guiding settings unavailable');
  }
}

Finder _field(String key) => find.descendant(
      of: find.byKey(ValueKey('guide-settle-$key')),
      matching: find.byType(EditableText),
    );

String _text(WidgetTester tester, String key) =>
    tester.widget<EditableText>(_field(key)).controller.text;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<HarnessHandle> _pumpEditor(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: GuideSettleSettings()),
    settle: false,
    extraOverrides: [appSettingsProvider.overrideWith(_SeedSettings.new)],
  );
  await _settle(tester);
  return handle;
}

void _drainOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('the editor shows the stored settle and dither settings',
      (tester) async {
    _seed = const AppSettingsState(
      settleThreshold: 2.0,
      settleTime: 12,
      settleTimeout: 95,
      ditherScale: 'Large',
    );
    await _pumpEditor(tester);
    _drainOverflow(tester);

    expect(_text(tester, 'threshold'), '2');
    expect(_text(tester, 'time'), '12');
    expect(_text(tester, 'timeout'), '95');
    expect(find.text('Large · 10 px'), findsOneWidget,
        reason: 'the dither size is the bucket it is stored as');
  });

  testWidgets('a value past the bounds is held to the settings table range',
      (tester) async {
    _seed = const AppSettingsState(settleTimeout: 40, settleThreshold: 2.0);
    final handle = await _pumpEditor(tester);

    await tester.enterText(_field('timeout'), '999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    await tester.enterText(_field('threshold'), '9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    final settings = handle.container.read(appSettingsProvider).value!;
    expect(settings.settleTimeout, AppSettingDefs.settleTimeout.inputMax);
    expect(settings.settleThreshold, AppSettingDefs.settleThreshold.inputMax);
    expect(GuideSettle.of(settings).timeoutSeconds, 180);
  });

  testWidgets('a setting saved elsewhere shows in an open editor',
      (tester) async {
    _seed = const AppSettingsState(settleThreshold: 2.0, settleTime: 10);
    final handle = await _pumpEditor(tester);

    await tester.runAsync(() async {
      await handle.container
          .read(appSettingsProvider.notifier)
          .setSettleTime(25);
    });
    await _settle(tester);

    expect(_text(tester, 'time'), '25');
    expect(_text(tester, 'threshold'), '2');
  });

  testWidgets('the Guiding screen and Imaging edit with the same editor',
      (tester) async {
    _seed = const AppSettingsState();
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      settle: false,
      extraOverrides: [appSettingsProvider.overrideWith(_SeedSettings.new)],
    );
    await _settle(tester);
    _drainOverflow(tester);
    expect(find.byType(GuideSettleSettings), findsOneWidget);

    await pumpAppScreen(
      tester,
      SingleChildScrollView(
        child: GuidingPanel(colors: SkotiqColors.dark),
      ),
      settle: false,
      extraOverrides: [appSettingsProvider.overrideWith(_SeedSettings.new)],
    );
    await _settle(tester);
    expect(find.byType(GuideSettleSettings), findsOneWidget);
  });

  testWidgets('a settings outage says so and offers a retry', (tester) async {
    _settingsLoadAttempts = 0;

    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      settle: false,
      extraOverrides: [
        appSettingsProvider.overrideWith(_FailingSettingsLoad.new),
      ],
    );
    await tester.pump();
    await tester.pump();
    _drainOverflow(tester);

    expect(
      find.textContaining('Guiding defaults unavailable'),
      findsOneWidget,
    );
    expect(_settingsLoadAttempts, 1);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pump();
    await tester.pump();
    expect(_settingsLoadAttempts, 2);
  });
}
