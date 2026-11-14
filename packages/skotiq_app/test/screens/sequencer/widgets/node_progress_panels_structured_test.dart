import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_progress_panels.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('exposure progress panel prefers structured detail',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: getProgressPanelForNode(
          node: ExposureNode(
            filter: 'L',
            count: 99,
            durationSecs: 120,
          ),
          colors: SkotiqColors.dark,
          progressPercent: 40,
          progressDetail: '',
          structuredProgressDetail: const ExposureInstructionProgressDetail(
            frame: 4,
            total: 9,
            durationSecs: 210,
          ),
        ),
      ),
    ));

    expect(find.text('4 / 9 frames'), findsOneWidget);
    expect(find.text('210'), findsOneWidget);
  });

  testWidgets('exposure progress panel keeps legacy detail fallback',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: getProgressPanelForNode(
          node: ExposureNode(
            filter: 'L',
            count: 10,
            durationSecs: 120,
          ),
          colors: SkotiqColors.dark,
          progressPercent: 40,
          progressDetail: 'Frame 3/10',
        ),
      ),
    ));

    expect(find.text('3 / 10 frames'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
  });

  Future<void> pumpPanel(
    WidgetTester tester,
    SequenceNode node, {
    required String line,
    InstructionProgressDetail? detail,
  }) =>
      tester.pumpWidget(MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: getProgressPanelForNode(
            node: node,
            colors: SkotiqColors.dark,
            progressPercent: 40,
            progressDetail: line,
            structuredProgressDetail: detail,
          ),
        ),
      ));

  // The step's line carries no cooler power, so a panel that read the line
  // never drew the gauge.
  testWidgets(
      'the cooling panel shows the sensor, the set-point and the '
      'cooler power the step read', (tester) async {
    await pumpPanel(
      tester,
      CoolCameraNode(),
      line: '-4.5°C → -10.0°C',
      detail: const ThermalInstructionProgressDetail(
        currentTempC: -4.5,
        targetTempC: -10,
        coolerPowerPercent: 62,
      ),
    );

    expect(find.text('-4.5°C'), findsOneWidget);
    expect(find.text('-10.0°C'), findsOneWidget);
    expect(find.text('Power'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
  });

  testWidgets(
      'a warming step with no sensor reading shows none, not its '
      'target', (tester) async {
    await pumpPanel(
      tester,
      WarmCameraNode(),
      line: '→ 20.0°C',
      detail: const ThermalInstructionProgressDetail(targetTempC: 20),
    );

    expect(find.text('--°C'), findsOneWidget);
    expect(find.text('20.0°C'), findsOneWidget);
    expect(find.text('Power'), findsNothing);
  });

  // "attempt 2/3 sep 41.5\"": the first number in the line is the attempt.
  testWidgets('the centering panel shows the separation, not the attempt', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      CenterNode(),
      line: 'attempt 2/3 sep 41.5"',
      detail: const CenterInstructionProgressDetail(
        attempt: 2,
        maxAttempts: 3,
        lastSeparationArcsec: 41.5,
      ),
    );

    expect(find.text('41.5" remaining'), findsOneWidget);
  });

  testWidgets('a centering step that has not solved yet shows no separation', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      CenterNode(),
      line: 'attempt 1/3',
      detail: const CenterInstructionProgressDetail(attempt: 1, maxAttempts: 3),
    );

    expect(find.textContaining('remaining'), findsNothing);
  });
}
