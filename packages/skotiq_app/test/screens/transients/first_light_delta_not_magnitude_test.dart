// A self-discovered transient must never be announced as a naked-eye object.
//
// Reproduced defect: Analytics > Science > Observing Alerts rendered a First
// Light detection as "NS J13.50+47.2 / Supernova ... mag 2.4 [NAKED EYE]". The
// detection's only photometric quantity is `delta_mag` = -2.35, a brightness
// CHANGE against the atlas template with no photometric zero point behind it —
// the table has no apparent-magnitude column at all. The mapper fed |delta| into
// `TransientAlert.magnitude`, which `TransientCard` buckets NAKED EYE (<=6) /
// BINOCULAR (<=10) / SMALL SCOPE (<=14). Since a difference-image delta larger
// than ~6 mag is essentially impossible, EVERY self-discovery with a measured
// delta was announced brighter than Polaris.
//
// This test drives the production wiring end to end — the real
// `transientAlertFromDetection`, the real `activeTransientAlertsProvider`
// contract and the real `TransientCard` — because a mapper-only assertion would
// not catch the card growing its own delta-to-magnitude fallback.

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

/// The reproduced row, mapped through the SAME production mapper the Observing
/// Alerts feed uses: kind=newSource, delta_mag=-2.35, snr=18.4, reviewed.
TransientAlert _firstLightAlert({double? deltaMag = -2.35}) {
  return transientAlertFromDetection(
    TransientDetectionRow(
      id: 1,
      sessionId: 1,
      capturedImageId: 42,
      tileId: 261982,
      detectedAt: DateTime.utc(2026, 7, 30, 2, 15),
      raDeg: 202.4694,
      decDeg: 47.1953,
      residualFlux: 18400.0,
      deltaMag: deltaMag,
      snr: 18.4,
      fwhm: 2.41,
      eccentricity: 0.12,
      positionAngleDeg: 0.0,
      kind: 'newSource',
      catalogMatch: null,
      confidence: 0.82,
      reviewed: true,
      dismissed: false,
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  TransientAlert alert, {
  Size size = const Size(1100, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
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

  testWidgets('a First Light detection is not given a brightness bucket', (
    tester,
  ) async {
    final alert = _firstLightAlert();
    await _pump(tester, alert);

    // The card is on screen at all, so the assertions below are about the card
    // and not about an empty feed.
    expect(find.byType(TransientCard), findsOneWidget);
    expect(find.text(alert.name), findsOneWidget);

    for (final bucket in const ['NAKED EYE', 'BINOCULAR', 'SMALL SCOPE']) {
      expect(
        find.text(bucket),
        findsNothing,
        reason: 'a brightness bucket claims an apparent magnitude the '
            'difference-image pipeline never measured',
      );
    }
    expect(
      find.textContaining(RegExp(r'^mag \d')),
      findsNothing,
      reason: 'no apparent magnitude exists for a First Light detection',
    );
  });

  testWidgets('the brightness CHANGE is shown as a delta instead', (
    tester,
  ) async {
    await _pump(tester, _firstLightAlert());

    expect(
      find.descendant(
        of: find.byType(TransientCard),
        matching: find.textContaining('Δ2.35 mag brighter'),
      ),
      findsOneWidget,
      reason: 'the measured quantity must still reach the operator',
    );
  });

  testWidgets('the delta survives a phone-width card', (tester) async {
    // The delta rides in the classification line. As a Row of unconstrained
    // Texts anything past the card's width is clipped (and throws a RenderFlex
    // overflow), so on a phone the brightness figure disappears with nothing
    // put in its place.
    await _pump(tester, _firstLightAlert(), size: const Size(390, 844));

    expect(
      find.descendant(
        of: find.byType(TransientCard),
        matching: find.textContaining('Δ2.35 mag brighter'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a detection with no measured delta shows no delta claim', (
    tester,
  ) async {
    await _pump(tester, _firstLightAlert(deltaMag: null));

    expect(find.byType(TransientCard), findsOneWidget);
    expect(find.textContaining('Δ'), findsNothing);
    expect(find.textContaining(RegExp(r'^mag \d')), findsNothing);
  });
}
