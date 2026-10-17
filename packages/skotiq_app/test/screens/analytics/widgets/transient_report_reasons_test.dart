// Every unavailable submission network has to say why.
//
// Observed defect: with a confirmed newSource detection and no credentials
// configured, the panel opened on TNS with its red reason shown; clicking the
// AAVSO chip and the MPC chip did nothing at all (a disabled chip has onTap
// null) and no explanation for either ever appeared. The app had already
// computed both reasons — "MPC astrometry is for moving objects..." and the
// AAVSO one — and rendered them only for `_format`, which the user could not
// move onto a disabled network. The text was written and unreachable.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/transient_report_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// No observer code, no MPC code, no TNS credentials — a fresh profile.
class _NoCredentialsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

final _detection = TransientDetectionRow(
  id: 9,
  sessionId: 3,
  capturedImageId: 44,
  tileId: 1,
  detectedAt: DateTime.utc(2026, 8, 1, 9),
  raDeg: 83.8,
  decDeg: -5.4,
  residualFlux: 1000,
  deltaMag: -0.5,
  snr: 28.4,
  fwhm: 2.1,
  eccentricity: 0.2,
  positionAngleDeg: 0,
  kind: 'newSource',
  catalogMatch: null,
  confidence: 0.95,
  reviewed: true,
  dismissed: false,
);

/// Not confirmed yet: one blocker covers all three networks.
final _unreviewed = TransientDetectionRow(
  id: 10,
  sessionId: 3,
  capturedImageId: 44,
  tileId: 1,
  detectedAt: DateTime.utc(2026, 8, 1, 9),
  raDeg: 83.8,
  decDeg: -5.4,
  residualFlux: 1000,
  deltaMag: -0.5,
  snr: 28.4,
  fwhm: 2.1,
  eccentricity: 0.2,
  positionAngleDeg: 0,
  kind: 'newSource',
  catalogMatch: null,
  confidence: 0.95,
  reviewed: false,
  dismissed: false,
);

Widget _panel(TransientDetectionRow detection) => ProviderScope(
      overrides: [
        scienceSettingsProvider.overrideWith(_NoCredentialsNotifier.new),
        sessionFrameCalibrationsProvider.overrideWith(
          (ref, sessionId) =>
              Stream.value(const <FramePhotometricCalibrationRow>[]),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: TransientReportPanel(
              colors: SkotiqColors.dark,
              detections: [detection],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a disabled AAVSO and MPC chip each state their own reason',
      (tester) async {
    await tester.pumpWidget(_panel(_detection));
    await tester.pumpAndSettle();

    // All three chips are inert without credentials, and each one is marked
    // disabled so it READS as unavailable — a null onTap alone rendered a chip
    // pixel-identical to one the operator simply had not picked yet.
    for (final label in ['AAVSO', 'MPC', 'TNS']) {
      final chip = tester.widget<SkotiqChip>(
        find.widgetWithText(SkotiqChip, label),
      );
      expect(chip.onTap, isNull, reason: '$label needs credentials');
      expect(
        chip.enabled,
        isFalse,
        reason: '$label is unavailable and must look it',
      );
    }

    // ...so all three reasons must be on screen without any interaction.
    expect(
      find.textContaining('MPC astrometry is for moving objects'),
      findsOneWidget,
    );
    expect(find.textContaining('AAVSO:'), findsOneWidget);
    expect(find.textContaining('TNS submission needs your bot id'),
        findsOneWidget);
  });

  testWidgets("AAVSO's notice names the blocker no setting can clear",
      (tester) async {
    // The fresh profile has neither an observer code NOR a photometric
    // zeropoint for the detection's frame, and AAVSO requires both. Naming only
    // the observer code sent the operator to Settings > Science to set the one
    // field the app said was in the way, after which AAVSO was still disabled
    // behind an entirely different blocker they cannot clear there. The
    // un-fixable one has to be on screen the first time.
    await tester.pumpWidget(_panel(_detection));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('photometric zeropoint'),
      findsOneWidget,
      reason: 'the frame has no zeropoint, so an observer code alone will not '
          'enable AAVSO — say so before sending the operator to Settings',
    );
    expect(
      find.textContaining('observer code'),
      findsOneWidget,
      reason: 'the observer code is a real blocker too and must still be named',
    );
  });

  testWidgets('an unconfirmed detection states its one shared blocker once',
      (tester) async {
    await tester.pumpWidget(_panel(_unreviewed));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Not yet confirmed'),
      findsOneWidget,
      reason: 'one blocker covers all three networks; say it once',
    );
  });
}
