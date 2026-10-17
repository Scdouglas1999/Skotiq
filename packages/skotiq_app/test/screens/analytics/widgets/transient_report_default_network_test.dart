// The submit panel must not open on a network the operator cannot use.
//
// Observed defect: _format was hard-coded to TNS, so an observer with an MPC
// observatory code (or an AAVSO observer code) but no TNS bot credentials met a
// disabled 'Submit to TNS' plus a blocker notice, while the network that WOULD
// have worked sat unmentioned behind a chip. Nothing here changes which network
// wins when more than one is usable — TNS still does.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/transient_report_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// An observatory code and nothing else — the MPC report is the one thing this
/// profile can actually produce.
class _MpcOnlyNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async =>
      const ScienceSettings(mpcObservatoryCode: 'W34');
}

/// Nothing configured at all: no network is usable, so the panel must leave the
/// selection where it is rather than shuffling the blocker it names.
class _NoCredentialsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

TransientDetectionRow _mover() => TransientDetectionRow(
      id: 9,
      sessionId: 3,
      capturedImageId: 44,
      tileId: 1,
      detectedAt: DateTime.utc(2026, 8, 1, 9),
      raDeg: 83.8,
      decDeg: -5.4,
      residualFlux: 1000,
      deltaMag: null,
      snr: 28.4,
      fwhm: 2.1,
      eccentricity: 0.62,
      positionAngleDeg: 41,
      kind: 'movingStreak',
      catalogMatch: null,
      confidence: 0.9,
      reviewed: true,
      dismissed: false,
    );

Widget _panel(Override settings) => ProviderScope(
      overrides: [
        settings,
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
              detections: [_mover()],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('opens on the network that works, not on a blocked TNS',
      (tester) async {
    await tester.pumpWidget(
      _panel(scienceSettingsProvider.overrideWith(_MpcOnlyNotifier.new)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Submit to TNS'), findsNothing);
    final primary = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Export report'),
    );
    expect(primary.onPressed, isNotNull, reason: 'MPC is fully configured');

    final mpcChip = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'MPC'),
    );
    expect(mpcChip.selected, isTrue);
  });

  testWidgets('with nothing configured it stays on TNS and says why',
      (tester) async {
    await tester.pumpWidget(
      _panel(scienceSettingsProvider.overrideWith(_NoCredentialsNotifier.new)),
    );
    await tester.pumpAndSettle();

    final tnsChip = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'TNS'),
    );
    expect(tnsChip.selected, isTrue);
    expect(find.text('Submit to TNS'), findsOneWidget);
    expect(find.textContaining('TNS submission needs your bot id'),
        findsOneWidget);
  });
}
