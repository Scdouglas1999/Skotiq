@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/widgets/night_report_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'surface_golden_harness.dart';

/// Renders [NightReportPanel] (the Night Doctor verdict) to inspectable review
/// PNGs in `docs/design/goldens/`. Not pixel-diff guards — the assertions only
/// confirm a real, non-empty image was produced; the PNG is the deliverable a
/// reviewer eyeballs.
void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  Future<void> capture(
    WidgetTester tester, {
    required String fileName,
    required ThemeData theme,
    required SkotiqColors colors,
    required NightReport? report,
  }) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          backgroundColor: colors.background,
          body: Center(
            child: SingleChildScrollView(
              child: RepaintBoundary(
                key: boundaryKey,
                child: Container(
                  width: 760,
                  color: colors.background,
                  padding: const EdgeInsets.all(SkotiqTokens.spaceXl),
                  child: NightReportPanel(report: report),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: fileName,
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  }

  testWidgets('night report panel — populated (dark)', (tester) async {
    await capture(
      tester,
      fileName: 'morning-report-night-report.png',
      theme: SkotiqTheme.dark,
      colors: SkotiqColors.dark,
      report: _fakeReport(),
    );
  });

  testWidgets('night report panel — analysis pending (dark)', (tester) async {
    await capture(
      tester,
      fileName: 'morning-report-night-report-pending.png',
      theme: SkotiqTheme.dark,
      colors: SkotiqColors.dark,
      report: null,
    );
  });
}

NightReport _fakeReport() {
  return NightReport(
    score: 72,
    headline: 'Solid night — focus drifted late, but most subs are keepers.',
    createdAt: DateTime.utc(2026, 6, 7, 5, 30),
    findings: const [
      NightFinding(
        id: 'cloud_intrusion',
        severity: NightFindingSeverity.critical,
        title: 'Clouds cost 6 subs',
        explanation:
            'Background flux spiked between 03:10 and 03:40 — six subs show '
            'washed-out backgrounds and dropped star counts consistent with '
            'thin high cloud passing through.',
        advice:
            'check the all-sky forecast and pause acquisition when transparency '
            'drops below 70%.',
        evidenceSubIds: [41, 42, 43, 44, 45, 46],
        metricSeries: [
          120,
          118,
          121,
          119,
          240,
          280,
          260,
          255,
          130,
          122,
          119,
          120,
        ],
      ),
      NightFinding(
        id: 'focus_drift',
        severity: NightFindingSeverity.warn,
        title: 'Focus drifted as the night cooled',
        explanation:
            'Median HFR rose from 2.1px to 3.0px over four hours, tracking the '
            'temperature drop. No autofocus run fired after midnight.',
        advice: 'enable temperature-triggered autofocus at a 1.5°C delta.',
        evidenceSubIds: [58, 59, 60, 61],
        metricSeries: [2.1, 2.2, 2.2, 2.4, 2.5, 2.7, 2.8, 3.0],
      ),
      NightFinding(
        id: 'guiding_good',
        severity: NightFindingSeverity.info,
        title: 'Guiding was excellent',
        explanation:
            'Total RMS held at 0.42" for the whole session with no spikes — '
            'mount and seeing cooperated.',
        advice: '',
        evidenceSubIds: [],
        metricSeries: [0.45, 0.41, 0.43, 0.40, 0.42, 0.41, 0.42],
      ),
    ],
  );
}
