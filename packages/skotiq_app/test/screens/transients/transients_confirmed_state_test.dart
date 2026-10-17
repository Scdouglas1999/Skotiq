// Two views of one detection, on two tabs of one screen, must not disagree.
//
// Reproduced defect: pressing Confirm on a First Light candidate updated the
// row (reviewed = 1) and re-badged the card "Confirmed", but one tab across on
// Observing Alerts the same detection still carried a blue "New" badge and sat
// under the "New" filter. `transientAlertFromDetection` does map reviewed ->
// TransientAlertState.acknowledged; the Observing Alerts UI simply never read
// the alert's own state. It read `transientAlertStatesProvider`, a map only
// ever populated from the `transient_alert_state_<id>` settings rows the user's
// own queue/dismiss actions write, and fell back to `newAlert` on a miss — so
// the mapper's `acknowledged` was dead on this surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/transients/transients_screen.dart';
import 'package:skotiq_app/screens/transients/widgets/transient_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

class _FixedScienceSettings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

/// A First Light detection the user has confirmed, mapped through the SAME
/// production mapper the Observing Alerts feed uses.
TransientAlert _confirmedDetectionAlert({required bool reviewed}) {
  return transientAlertFromDetection(
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
}

Future<void> _pump(WidgetTester tester, TransientAlert alert) async {
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
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
        scienceSettingsProvider.overrideWith(_FixedScienceSettings.new),
        activeTransientAlertsProvider.overrideWith(
          (ref) => Stream.value([alert]),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: TransientsView())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() => registerFallbackValue(''));

  testWidgets('a confirmed detection is not badged New on Observing Alerts',
      (tester) async {
    final alert = _confirmedDetectionAlert(reviewed: true);
    expect(
      alert.state,
      TransientAlertState.acknowledged,
      reason: 'the mapper must mark a reviewed detection acknowledged',
    );

    await _pump(tester, alert);

    expect(find.text(alert.name), findsOneWidget);
    // Scope to the card: "New" is also a filter-chip label.
    expect(
      find.descendant(
        of: find.byType(TransientCard),
        matching: find.text('New'),
      ),
      findsNothing,
      reason: 'the same detection reads Confirmed one tab across',
    );
    expect(
      find.descendant(
        of: find.byType(TransientCard),
        matching: find.text('Seen'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unreviewed detection is still New', (tester) async {
    final alert = _confirmedDetectionAlert(reviewed: false);
    expect(alert.state, TransientAlertState.newAlert);

    await _pump(tester, alert);

    expect(
      find.descendant(
        of: find.byType(TransientCard),
        matching: find.text('New'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a confirmed detection does not sit under the New filter',
      (tester) async {
    final alert = _confirmedDetectionAlert(reviewed: true);
    await _pump(tester, alert);
    // Visible under the default (All) filter first, so the assertion below is
    // about the filter and not about an empty feed.
    expect(find.text(alert.name), findsOneWidget);

    await tester.tap(find.text('New').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.text(alert.name),
      findsNothing,
      reason: 'a confirmed detection must leave the New bucket',
    );
  });
}
