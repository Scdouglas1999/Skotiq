// Defect 5: the guiding screen's settle/dither controls must LOAD from the
// canonical persisted authority (AppSettings), VALIDATE + SAVE edits back
// through it, and SURVIVE screen reconstruction — never reset to local
// defaults on navigation.
//
// The assertions read the real `GuideControlsPanel` the screen builds, so they
// exercise the true hydration + persistence path end-to-end.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';
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

class _FailingSettleSettingsDao extends SettingsDao {
  _FailingSettleSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == 'settle_timeout') {
      throw StateError('settle write failed');
    }
    await super.setSetting(key, value);
  }
}

GuideControlsPanel _panel(WidgetTester tester) =>
    tester.widget<GuideControlsPanel>(find.byType(GuideControlsPanel));

void _drainOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('loads persisted settle/dither on (re)construction',
      (tester) async {
    _seed = const AppSettingsState(
      settleThreshold: 2.0,
      settleTimeout: 95,
      ditherScale: 'Large',
    );

    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      settle: false,
      extraOverrides: [appSettingsProvider.overrideWith(_SeedSettings.new)],
    );
    // Let the async settings build resolve and the screen re-hydrate.
    await tester.pump();
    await tester.pump();
    _drainOverflow(tester);

    final panel = _panel(tester);
    // NOT the hardcoded placeholders (1.5 / 60 / 5.0) — proof the fresh screen
    // read the persisted authority.
    expect(panel.settlePixels, 2.0);
    expect(panel.settleTimeout, 95.0);
    expect(panel.ditherAmount, 10.0); // 'Large' -> 10 px
  });

  testWidgets('edits validate (clamp) and save through the canonical authority',
      (tester) async {
    _seed = const AppSettingsState(
      settleThreshold: 2.0,
      settleTimeout: 40,
      ditherScale: 'Small',
    );

    final handle = await pumpAppScreen(
      tester,
      const GuidingScreen(),
      settle: false,
      extraOverrides: [appSettingsProvider.overrideWith(_SeedSettings.new)],
    );
    await tester.pump();
    await tester.pump();
    _drainOverflow(tester);

    // Drive an out-of-range timeout edit through the real screen callback.
    await tester.runAsync(() async {
      _panel(tester).onSettleTimeoutChanged!(9999);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    _drainOverflow(tester);

    final settings = handle.container.read(appSettingsProvider).value!;
    // Validated to the 30..180 range and persisted to the canonical field.
    expect(settings.settleTimeout, 180);

    // Dither amount persists as the canonical Small/Medium/Large bucket.
    await tester.runAsync(() async {
      _panel(tester).onDitherAmountChanged!(9.0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    _drainOverflow(tester);
    expect(
        handle.container.read(appSettingsProvider).value!.ditherScale, 'Large');
  });

  testWidgets('saved settle value survives a full screen reconstruction',
      (tester) async {
    _seed = const AppSettingsState(
      settleThreshold: 2.0,
      settleTimeout: 40,
      ditherScale: 'Small',
    );

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final backend = mockBackend();
    final db = mockDatabase();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        databaseProvider.overrideWithValue(db),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
        ),
        appSettingsProvider.overrideWith(_SeedSettings.new),
      ],
    );
    addTearDown(container.dispose);

    Future<void> pumpScreen(Key key) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: GuidingScreen(key: key),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      _drainOverflow(tester);
    }

    await pumpScreen(const ValueKey('first'));
    expect(_panel(tester).settleTimeout, 40.0);

    // Save an out-of-range edit; it clamps + persists to the canonical store.
    await tester.runAsync(() async {
      _panel(tester).onSettleTimeoutChanged!(9999);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    _drainOverflow(tester);
    expect(container.read(appSettingsProvider).value!.settleTimeout, 180);

    // A brand-new screen State must re-hydrate from the persisted value, not
    // fall back to the local default.
    await pumpScreen(const ValueKey('second'));
    expect(_panel(tester).settleTimeout, 180.0);
  });

  testWidgets('settings outage disables persisted controls and exposes a retry',
      (tester) async {
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
    expect(
      find.textContaining('Bad state: guiding settings unavailable'),
      findsOneWidget,
    );
    expect(_panel(tester).onDitherAmountChanged, isNull);
    expect(_panel(tester).onSettlePixelsChanged, isNull);
    expect(_panel(tester).onSettleTimeoutChanged, isNull);
    expect(_settingsLoadAttempts, 1);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pump();
    await tester.pump();

    expect(_settingsLoadAttempts, 2);
    expect(_panel(tester).onSettleTimeoutChanged, isNull);
  });

  testWidgets('failed settle write reports the error and restores authority',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);

    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      database: database,
      settle: false,
      extraOverrides: [
        settingsDaoProvider.overrideWithValue(
          _FailingSettleSettingsDao(database),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();
    _drainOverflow(tester);

    final original = _panel(tester).settleTimeout;
    expect(_panel(tester).onSettleTimeoutChanged, isNotNull);

    await tester.runAsync(() async {
      _panel(tester).onSettleTimeoutChanged!(120);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    _drainOverflow(tester);

    expect(_panel(tester).settleTimeout, original);
    expect(
      find.textContaining(
        'Could not save the settle timeout: Bad state: settle write failed',
      ),
      findsOneWidget,
    );
  });
}
