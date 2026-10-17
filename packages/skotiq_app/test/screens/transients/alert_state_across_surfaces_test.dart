// One detection, one state, on every surface that shows it.
//
// `transientAlertStatesProvider` is a map of the queue/dismiss actions taken
// through the alert surfaces themselves. It has no entry for a First Light
// detection, whose reviewed/dismissed state lives on its own row and reaches
// the UI as `TransientAlert.state`. Observing Alerts was fixed to resolve
// through `resolveTransientAlertState`, but the status-bar alert dropdown and
// the suggestions panel still read the map bare and fell back to `newAlert` on
// a miss — so a detection the user had just confirmed was re-badged NEW there.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/suggestions/widgets/transient_alerts_panel.dart';
import 'package:skotiq_app/widgets/transient_alert_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

/// A First Light detection mapped through the production mapper, so the alert
/// carries exactly the state its row does.
TransientAlert _detectionAlert({required bool reviewed}) =>
    transientAlertFromDetection(
      TransientDetectionRow(
        id: 1,
        sessionId: null,
        capturedImageId: null,
        tileId: 261982,
        detectedAt: DateTime.utc(2026, 8, 1, 3, 30),
        raDeg: 202.47,
        decDeg: 47.19,
        residualFlux: 1200.0,
        deltaMag: null,
        snr: 14.2,
        fwhm: 2.8,
        eccentricity: 0.12,
        positionAngleDeg: 0.0,
        kind: 'newSource',
        catalogMatch: null,
        confidence: 0.91,
        reviewed: reviewed,
        dismissed: false,
      ),
    );

Future<void> _pump(
    WidgetTester tester, Widget child, TransientAlert alert) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 900);
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
}

void main() {
  setUpAll(() => registerFallbackValue(''));

  group('suggestions panel', () {
    testWidgets('a confirmed detection is not re-badged NEW', (tester) async {
      final alert = _detectionAlert(reviewed: true);
      expect(alert.state, TransientAlertState.acknowledged);

      await _pump(tester, const TransientAlertsPanel(), alert);

      expect(find.text(alert.name), findsOneWidget);
      expect(
        find.text('NEW'),
        findsNothing,
        reason: 'the user already confirmed this detection',
      );
    });

    testWidgets('an unconfirmed detection still reads NEW', (tester) async {
      final alert = _detectionAlert(reviewed: false);
      expect(alert.state, TransientAlertState.newAlert);

      await _pump(tester, const TransientAlertsPanel(), alert);

      expect(find.text('NEW'), findsOneWidget);
    });
  });

  group('status-bar alert dropdown', () {
    testWidgets('a confirmed detection is not re-badged NEW', (tester) async {
      final alert = _detectionAlert(reviewed: true);

      await _pump(
        tester,
        // Anchored top-left: `_showDropdownMenu` derives the menu's right
        // inset from the badge's own x, so a centred badge leaves the popup
        // almost no width.
        const Align(
          alignment: Alignment.topLeft,
          child: TransientAlertBadge(showDropdown: true),
        ),
        alert,
      );
      await tester.tap(find.byType(TransientAlertBadge));
      await tester.pumpAndSettle();

      expect(find.text(alert.name), findsOneWidget);
      expect(
        find.text('NEW'),
        findsNothing,
        reason: 'the dropdown reads the same row as Observing Alerts',
      );
    });

    testWidgets('an unconfirmed detection still reads NEW', (tester) async {
      final alert = _detectionAlert(reviewed: false);

      await _pump(
        tester,
        // Anchored top-left: `_showDropdownMenu` derives the menu's right
        // inset from the badge's own x, so a centred badge leaves the popup
        // almost no width.
        const Align(
          alignment: Alignment.topLeft,
          child: TransientAlertBadge(showDropdown: true),
        ),
        alert,
      );
      await tester.tap(find.byType(TransientAlertBadge));
      await tester.pumpAndSettle();

      expect(find.text('NEW'), findsOneWidget);
    });
  });
}
