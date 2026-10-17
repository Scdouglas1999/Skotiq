// One transient type, one name and one severity colour, on every surface.
//
// `TransientType` was rendered by four independent switch statements — the
// Observing Alerts card, the suggestions panel tile, that same file's settings
// dialog, and the status-bar alert dropdown — and they disagreed. A gamma-ray
// burst was a 'Gamma-Ray Burst' on two screens and a 'GRB Afterglow' on a
// third; a variable star was drawn in the success colour on one screen, the
// warning colour on another and the accent colour on a third. Same detection,
// different name and different urgency depending on where you looked.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/suggestions/widgets/transient_alerts_panel.dart';
import 'package:skotiq_app/screens/transients/widgets/transient_card.dart';
import 'package:skotiq_app/widgets/transient_alert_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

TransientAlert _alert(TransientType type) => TransientAlert(
      id: 'a1',
      name: 'NS Test Object',
      type: type,
      raHours: 13.5,
      decDegrees: 47.2,
      magnitude: 14.1,
      discoveryTime: DateTime.utc(2026, 8, 1, 2),
      lastUpdated: DateTime.utc(2026, 8, 1, 3),
      source: TransientSource.tns,
    );

Future<void> _pump(WidgetTester tester, Widget child, TransientAlert alert,
    {bool tapBadge = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final dao = _MockSettingsDao();
  when(dao.getAllSettings).thenAnswer((_) async => <String, String>{});
  when(() => dao.getSetting(any())).thenAnswer((_) async => null);
  when(() => dao.setSetting(any(), any())).thenAnswer((_) async {});

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsDaoProvider.overrideWithValue(dao),
        loggingServiceProvider.overrideWithValue(_MockLogger()),
        activeTransientAlertsProvider.overrideWith(
          (ref) => Stream.value([alert]),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  if (tapBadge) {
    await tester.tap(find.byType(TransientAlertBadge));
    await tester.pumpAndSettle();
  }
}

/// The alert dropdown, anchored top-left because `_showDropdownMenu` derives
/// the menu's right inset from the badge's own x.
Widget get _dropdown => const Align(
      alignment: Alignment.topLeft,
      child: TransientAlertBadge(showDropdown: true),
    );

Widget _card(TransientAlert alert) => TransientCard(
      alert: alert,
      state: TransientAlertState.newAlert,
      onQueue: () async {},
      onPlan: () {},
      onViewInFraming: () {},
      onOpenScience: () {},
      onDismiss: () {},
    );

/// The 28x28 type chip both the panel tile and the dropdown row draw.
Icon _typeChipIcon(WidgetTester tester) {
  final icons = tester
      .widgetList<Icon>(find.byType(Icon))
      .where((icon) => icon.size == 14)
      .toList();
  expect(icons, isNotEmpty, reason: 'the type chip renders a 14px icon');
  return icons.first;
}

void main() {
  setUpAll(() => registerFallbackValue(''));

  // The full-name spelling the Observing Alerts card and the status-bar
  // dropdown already agreed on; the suggestions panel is the outlier.
  const fullLabels = <TransientType, String>{
    TransientType.nova: 'Nova',
    TransientType.supernova: 'Supernova',
    TransientType.comet: 'Comet',
    TransientType.cataclysmic: 'Cataclysmic Variable',
    TransientType.asteroid: 'Asteroid',
    TransientType.variableStar: 'Variable Star',
    TransientType.gammaRayBurst: 'Gamma-Ray Burst',
    TransientType.other: 'Other',
  };

  for (final entry in fullLabels.entries) {
    testWidgets('${entry.key.name} is named the same on every alert surface',
        (tester) async {
      final alert = _alert(entry.key);

      await _pump(tester, const TransientAlertsPanel(), alert);
      expect(find.text(entry.value), findsOneWidget,
          reason: 'suggestions panel tile');

      await _pump(tester, _dropdown, alert, tapBadge: true);
      expect(find.text(entry.value), findsOneWidget,
          reason: 'status-bar alert dropdown');

      await _pump(tester, _card(alert), alert);
      expect(
        find.textContaining(entry.value, findRichText: true),
        findsAtLeastNWidgets(1),
        reason: 'Observing Alerts card',
      );
    });
  }

  testWidgets('a type is drawn in one severity colour on every surface',
      (tester) async {
    // variableStar was the widest disagreement: success / warning / accent.
    final alert = _alert(TransientType.variableStar);

    await _pump(tester, const TransientAlertsPanel(), alert);
    final panelIcon = _typeChipIcon(tester);

    await _pump(tester, _dropdown, alert, tapBadge: true);
    final dropdownIcon = _typeChipIcon(tester);

    expect(panelIcon.color, dropdownIcon.color,
        reason: 'the same detection cannot be two different urgencies');
    expect(panelIcon.icon, dropdownIcon.icon,
        reason: 'nor two different glyphs');
  });
}
