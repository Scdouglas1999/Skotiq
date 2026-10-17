import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/element_refresh_card.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Controllable [ElementRefreshService] stand-in for the card tests. It never
/// touches disk or the network; knobs decide whether the config authority
/// hangs (loading), errors, or resolves, and whether a save succeeds.
class _FakeService extends ElementRefreshService {
  _FakeService({
    this.hang = false,
    this.configError,
    ElementRefreshConfig? config,
    this.saveThrows = false,
  })  : config = config ?? const ElementRefreshConfig(),
        super(cacheDirectory: Directory.systemTemp.path);

  bool hang;
  Object? configError;
  ElementRefreshConfig config;
  bool saveThrows;
  int loadConfigCalls = 0;
  int saveCalls = 0;
  final Completer<ElementRefreshConfig> _never = Completer();

  @override
  Future<ElementRefreshConfig> loadConfig() {
    loadConfigCalls++;
    if (hang) return _never.future; // never completes -> stays loading
    if (configError != null) return Future.error(configError!);
    return Future.value(config);
  }

  @override
  Future<RefreshedElements> loadCached() async => const RefreshedElements();

  @override
  bool isStale(RefreshedElements cached, ElementRefreshConfig cfg) => false;

  @override
  Future<RefreshedElements> refresh({ElementRefreshConfig? config}) async =>
      const RefreshedElements();

  @override
  Future<void> saveConfig(ElementRefreshConfig cfg) async {
    saveCalls++;
    if (saveThrows) throw StateError('disk full');
    config = cfg;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final scheduleDropdown = find.byType(DropdownButton<ElementRefreshSchedule>);

  ElementRefreshSchedule dropdownValue(WidgetTester tester) => tester
      .widget<DropdownButton<ElementRefreshSchedule>>(scheduleDropdown)
      .value!;

  Future<void> pumpCard(WidgetTester tester, _FakeService fake) async {
    await pumpAppScreen(
      tester,
      const ElementRefreshCard(),
      extraOverrides: [
        elementRefreshServiceProvider.overrideWithValue(fake),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  // The card must not promise MPCORB (1.4 M objects) and deliver the Minor
  // Planet Center's Bright Minor Planets file (312 bodies), leaving an observer
  // who cannot find their asteroid to conclude the search is broken.
  testWidgets('the card names the source it actually fetches', (tester) async {
    await pumpCard(tester, _FakeService());

    expect(find.textContaining('Soft00Bright'), findsOneWidget);
    expect(find.textContaining('not the full MPCORB'), findsOneWidget);
  });

  // "Refresh now" must produce completion feedback the operator notices, not
  // just a date buried in a small status line.
  testWidgets('a completed refresh is acknowledged with its counts',
      (tester) async {
    await pumpCard(tester, _FakeService());

    await tester.tap(find.widgetWithText(SkotiqButton, 'Refresh now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Elements refreshed'), findsOneWidget);
  });

  testWidgets('config loading shows a spinner and no schedule control',
      (tester) async {
    final fake = _FakeService(hang: true);
    await pumpCard(tester, fake);

    expect(find.text('Loading refresh configuration…'), findsOneWidget);
    expect(scheduleDropdown, findsNothing);
  });

  testWidgets(
      'config error shows detail + Retry and no schedule control; Retry '
      'recovers', (tester) async {
    final fake = _FakeService(configError: StateError('corrupt config'));
    await pumpCard(tester, fake);

    expect(find.text('Auto-refresh configuration unavailable'), findsOneWidget);
    expect(find.textContaining('corrupt config'), findsWidgets);
    expect(scheduleDropdown, findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Retry'), findsOneWidget);

    // The authority recovers; Retry must re-read it and restore the control.
    fake.configError = null;
    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Auto-refresh configuration unavailable'), findsNothing);
    expect(scheduleDropdown, findsOneWidget);
  });

  testWidgets('successful schedule save commits and confirms', (tester) async {
    final fake = _FakeService(
      config: const ElementRefreshConfig(
        schedule: ElementRefreshSchedule.weekly,
      ),
    );
    await pumpCard(tester, fake);

    expect(scheduleDropdown, findsOneWidget);
    expect(dropdownValue(tester), ElementRefreshSchedule.weekly);

    await tester.tap(scheduleDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monthly').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.saveCalls, 1);
    expect(fake.config.schedule, ElementRefreshSchedule.monthly);
    // Committed only after persistence: the bound value now reflects the save.
    expect(dropdownValue(tester), ElementRefreshSchedule.monthly);
    expect(find.text('Auto-refresh set to Monthly'), findsOneWidget);
    expect(find.textContaining('Could not save schedule'), findsNothing);
  });

  testWidgets('failed schedule save is visible, uncommitted, and retryable',
      (tester) async {
    final fake = _FakeService(
      config: const ElementRefreshConfig(
        schedule: ElementRefreshSchedule.weekly,
      ),
      saveThrows: true,
    );
    await pumpCard(tester, fake);

    await tester.tap(scheduleDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daily').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.saveCalls, 1);
    expect(find.textContaining('Could not save schedule'), findsOneWidget);
    // Not visually committed: the bound value is still the prior selection.
    expect(dropdownValue(tester), ElementRefreshSchedule.weekly);

    // Retryable: the next save succeeds and then commits.
    fake.saveThrows = false;
    await tester.tap(scheduleDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daily').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.saveCalls, 2);
    expect(fake.config.schedule, ElementRefreshSchedule.daily);
    expect(dropdownValue(tester), ElementRefreshSchedule.daily);
    expect(find.textContaining('Could not save schedule'), findsNothing);
  });
}
