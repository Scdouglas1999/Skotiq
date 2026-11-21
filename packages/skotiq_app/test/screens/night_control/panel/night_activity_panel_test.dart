import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/night_activity_panel.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/night_activity_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import '../../../golden/surface_golden_harness.dart';
import 'panel_test_support.dart';

final _activity = StateProvider<NightActivityVm>((ref) => const NightActivityVm(
      kind: NightActivityKind.capture,
      title: NightText('nightActivityCapture'),
      target: 'M74',
      progress: 0.5,
      metrics: [MetricVm(label: NightText('nightPanelGain'), value: '76')],
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(SurfaceGoldenHarness.ensureCaptureFonts);
  testWidgets(
      'one panel follows operations and does not expose manual autofocus controls',
      (tester) async {
    final container = ProviderContainer(overrides: [
      ...panelOverrides(board: NightFixtures.running()),
      nightActivityProvider.overrideWith((ref) => ref.watch(_activity)),
    ]);
    addTearDown(container.dispose);
    await pumpPanel(tester,
        child: const NightActivityPanel(), overrides: [], container: container);
    final before = tester.getTopLeft(find.byType(NightActivityPanel));
    expect(find.text('Capturing'), findsOneWidget);
    expect(
        tester.widget<SkotiqProgressBar>(find.byType(SkotiqProgressBar)).value,
        0.5);
    container.read(_activity.notifier).state = const NightActivityVm(
        kind: NightActivityKind.focus, title: NightText('nightActivityFocus'));
    await tester.pump();
    await tester.pump(SkotiqTokens.durationNormal);
    expect(find.byType(VCurveChart), findsOneWidget);
    expect(find.byType(SkotiqProgressBar), findsNothing);
    expect(find.text('Capturing'), findsNothing);
    expect(find.text('Cancel autofocus'), findsNothing);
    expect(find.text('Settings…'), findsNothing);
    expect(tester.getTopLeft(find.byType(NightActivityPanel)), before);
    container.read(_activity.notifier).state = const NightActivityVm(
        kind: NightActivityKind.paused,
        title: NightText('nightActivityPaused'),
        detail: 'Clouds detected');
    await tester.pump();
    await tester.pump(SkotiqTokens.durationNormal);
    expect(find.byType(VCurveChart), findsNothing);
    expect(find.byType(SkotiqProgressBar), findsNothing);
    expect(find.text('Clouds detected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [260.0, 360.0]) {
    for (final kind in NightActivityKind.values
        .where((k) => k != NightActivityKind.ready)) {
      testWidgets('${kind.name} fits a $width-wide themed panel',
          (tester) async {
        final key = GlobalKey();
        await pumpPanel(tester,
            size: Size(width, 600),
            child: RepaintBoundary(key: key, child: const NightActivityPanel()),
            overrides: [
              ...panelOverrides(board: NightFixtures.running()),
              nightActivityProvider.overrideWithValue(NightActivityVm(
                kind: kind,
                title: NightText(
                    'nightActivity${kind.name[0].toUpperCase()}${kind.name.substring(1)}'),
                target: 'M74 · The Phantom Galaxy',
                detail: kind == NightActivityKind.failed
                    ? 'Plate solving failed. The sequence is stopped.'
                    : null,
                progress: kind == NightActivityKind.capture ? 0.67 : null,
                metrics: switch (kind) {
                  NightActivityKind.capture => const [
                      MetricVm(
                          label: NightText('nightScopeSolveFilter'),
                          value: 'Ha'),
                      MetricVm(
                          label: NightText('nightScopeSolveExposure'),
                          value: '180.0 s'),
                      MetricVm(
                          label: NightText('nightPanelGain'), value: '139'),
                      MetricVm(
                          label: NightText('nightPanelOffset'), value: '21'),
                      MetricVm(
                          label: NightText('nightPanelSensor'),
                          value: '−10.0 °C'),
                      MetricVm(
                          label: NightText('nightActivityFrames'),
                          value: '12 / 60'),
                      MetricVm(
                          label: NightText('nightSessionStatRemaining'),
                          value: '60.0 s'),
                    ],
                  NightActivityKind.slew ||
                  NightActivityKind.center ||
                  NightActivityKind.flip =>
                    const [
                      MetricVm(
                          label: NightText('nightScopeRaJNow'),
                          value: '1h 36m 42s'),
                      MetricVm(
                          label: NightText('nightScopeDecJNow'),
                          value: '+15° 47′ 01″'),
                      MetricVm(
                          label: NightText('nightActivityAltitude'),
                          value: '63.2°'),
                      MetricVm(
                          label: NightText('nightActivityAzimuth'),
                          value: '175.8°'),
                      MetricVm(
                          label: NightText('nightActivityAttempt'),
                          value: '2 / 5'),
                      MetricVm(
                          label: NightText('nightScopeSolveOffTarget'),
                          value: '35.4″'),
                    ],
                  NightActivityKind.guide => const [
                      MetricVm(
                          label: NightText('nightActivityRaRms'),
                          value: '0.65″'),
                      MetricVm(
                          label: NightText('nightActivityDecRms'),
                          value: '0.48″'),
                      MetricVm(
                          label: NightText('nightActivityTotalRms'),
                          value: '0.81″'),
                    ],
                  _ => const [],
                },
              )),
            ]);
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        // Optional previews are actual widget renders, not design mockups.
        final directory = Platform.environment['SKOTIQ_ACTIVITY_PREVIEWS'];
        if (directory != null && width == 360) {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(directory).create(recursive: true);
            await File('$directory/${kind.name}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
