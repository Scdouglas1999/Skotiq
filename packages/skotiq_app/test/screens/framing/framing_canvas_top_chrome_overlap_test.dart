// The framing canvas's top chrome must never cover its own interactive chips.
//
// THE BUG: the on-canvas toolbar sat at `top: 16` inside a [Wrap] that flows onto
// a second line at narrow widths, while the floating target card and the
// equipment-status hint were each pinned at a literal `top: 60`. Below roughly
// 1100 px wide the wrapped second row landed exactly under those cards — and
// because the cards were LATER children of the same [Stack], they painted over
// it and absorbed its hits. The HiPS control was visible ghosting through
// the target card and could not be clicked at all.
//
// These tests pin geometry, not pixels: the toolbar's bottom edge must be above
// the cards' top edge, and the chip must be the widget that actually receives a
// tap at its own centre.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _target = FramingTarget(
  name: 'Custom Location',
  raHours: 5.588,
  decDegrees: -5.39,
);

Future<ui.Image> _image(int w, int h) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF102030),
  );
  return recorder.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image surveyImage;
  setUpAll(() async {
    surveyImage = await _image(800, 600);
  });
  tearDownAll(() => surveyImage.dispose());

  /// Pumps the canvas at [size] with a target resolved, labels on (so the
  /// floating target card is shown) and DSS2 red selected (so the tile-capable
  /// the HiPS control is present).
  Future<void> pumpCanvas(WidgetTester tester, Size size) async {
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: FramingCanvas(
                  colors: SkotiqColors.dark,
                  framingState: FramingState(
                    target: _target,
                    // Labels on => the floating target card renders.
                    showLabels: true,
                    surveySource: SurveySource.dss2Red,
                    surveyImage: surveyImage,
                    plateScale: const FramingPlateScale(
                      surveyFovWidthDeg: 2.0,
                      surveyFovHeightDeg: 1.5,
                      imagePixelWidth: 800,
                      imagePixelHeight: 600,
                    ),
                  ),
                  equipmentResult: null,
                  onPan: (_, __, ___) {},
                  onRotate: (_) {},
                  onAimChanged: (_, __) {},
                  onCanvasResized: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the HiPS control is present and hittable at a narrow canvas',
      (tester) async {
    // The reported repro width. The toolbar wraps here.
    await pumpCanvas(tester, const Size(1100, 720));

    final chip = find.byTooltip('HiPS tiles');
    expect(chip, findsOneWidget, reason: 'the tile toggle should be offered');

    // The chip's own centre must actually hit the chip — not a card painted
    // over it. hitTestable() resolves through the real Stack hit-test order.
    expect(
      find.byTooltip('HiPS tiles').hitTestable(),
      findsOneWidget,
      reason: 'the chip is covered by later Stack chrome and cannot be clicked',
    );
  });

  // One test per width: a single test that re-pumps in a loop leaks the
  // Riverpod auto-dispose scheduler's timer between containers.
  for (final width in const [1600.0, 1100.0, 900.0, 760.0]) {
    testWidgets(
      'the toolbar never overlaps the floating target card at ${width}px',
      (tester) async {
        await pumpCanvas(tester, Size(width, 720));

        final toolbarRect = tester.getRect(find.byTooltip('HiPS tiles'));
        final cardRect = tester.getRect(find.text('Custom Location'));

        expect(
          toolbarRect.bottom,
          lessThanOrEqualTo(cardRect.top),
          reason: 'the toolbar row runs into the target card '
              '(toolbar bottom=${toolbarRect.bottom}, card top=${cardRect.top})',
        );
      },
    );
  }

  testWidgets('the survey dropdown has room for its whole label',
      (tester) async {
    await pumpCanvas(tester, const Size(1100, 720));

    // The selected survey name must be laid out at its full intrinsic width —
    // a squeezed button dropped the first character ("DSS2 Red" -> ")SS2 Red").
    final label = find.text(SurveySource.dss2Red.displayName);
    expect(label, findsWidgets);

    final rendered = tester.getRect(label.first);
    final intrinsic = tester.renderObject<RenderBox>(label.first);
    expect(
      rendered.width + 0.5,
      greaterThanOrEqualTo(intrinsic.getMinIntrinsicWidth(double.infinity)),
      reason: 'the survey label is narrower than its text and is being clipped',
    );
  });
}
