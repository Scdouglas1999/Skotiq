// The framing canvas's chrome: four glass groups that never overlap each
// other or the camera frame, at the desktop, laptop and phone sizes, with a
// target, a mosaic, a rotated frame, and with no camera field set up.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_app/screens/framing/painters/framing_painters.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas_chrome.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// A 1016 mm reflector with an APS-H mono sensor: a 1.00° × 0.76° field.
const FramingEquipment _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 17.7,
  sensorHeightMm: 13.4,
  pixelSizeMicrons: 3.8,
  pixelsX: 4656,
  pixelsY: 3520,
  telescopeName: 'Test Newtonian',
  focalLengthMm: 1016,
  apertureMm: 254,
);

const FramingTarget _target = FramingTarget(
  name: 'NGC 7331',
  catalogId: 'NGC7331',
  raHours: 22.6178,
  decDegrees: 34.4156,
  magnitude: 9.5,
  sizeArcmin: 10,
);

/// The cutout Framing asks for at its default 2° preview.
const FramingPlateScale _surveyScale = FramingPlateScale(
  surveyFovWidthDeg: 2.0,
  surveyFovHeightDeg: 1.5,
  imagePixelWidth: 800,
  imagePixelHeight: 600,
);

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }

  @override
  void onCanvasResized(Size canvasSize) {}
}

Future<ui.Image> _survey() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 800, 600),
    Paint()..color = const Color(0xFFE0E0E0),
  );
  return recorder.endRecording().toImage(800, 600);
}

enum _Scene { target, mosaicRotated, noCamera }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image surveyImage;
  setUpAll(() async => surveyImage = await _survey());
  tearDownAll(() => surveyImage.dispose());

  FramingState stateFor(_Scene scene) => FramingState(
        target: _target,
        surveyImageBytes: Uint8List.fromList(const [0]),
        surveyImage: surveyImage,
        plateScale: _surveyScale,
        showGrid: false,
        mosaicEnabled: scene == _Scene.mosaicRotated,
        rotation: scene == _Scene.mosaicRotated ? 30 : 0,
        // The longest survey notice the app writes, with the image still on
        // screen from the last fetch.
        imageError: scene == _Scene.noCamera
            ? 'Survey image unavailable: could not reach the survey servers.'
            : null,
      );

  Future<Rect> pumpScene(WidgetTester tester, Size size, _Scene scene) async {
    await pumpAppScreen(
      tester,
      const FramingScreen(),
      size: size,
      settle: false,
      extraOverrides: [
        framingProvider.overrideWith(
          (ref) => _SeededFramingNotifier(ref, stateFor(scene)),
        ),
        framingFOVProvider.overrideWith(
          (ref) async => scene == _Scene.noCamera
              ? const FramingEquipmentResult(
                  status: FramingEquipmentStatus.noFocalLength,
                  profileName: 'Backyard 80ED',
                )
              : const FramingEquipmentResult(
                  status: FramingEquipmentStatus.ready,
                  equipment: _equipment,
                  profileName: '10" Newt',
                ),
        ),
        hipsFramingEnabledProvider.overrideWith((ref) => false),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    return tester.getRect(find.byType(FramingCanvas));
  }

  /// The camera frame with its rotation handle, rotated about the canvas
  /// center as it is drawn: four corners.
  List<Offset> reticleCorners(Rect canvas, double rotationDegrees) {
    final ppd = _surveyScale.pixelsPerDegree(canvas.size, 1.0);
    final halfW = _equipment.fovWidthDeg * ppd / 2;
    final halfH = _equipment.fovHeightDeg * ppd / 2;
    final top = halfH +
        FramingFOVPainter.rotationHandleGap +
        FramingFOVPainter.rotationHandleRadius;
    final a = rotationDegrees * math.pi / 180;
    return [
      for (final c in [
        Offset(-halfW, -top),
        Offset(halfW, -top),
        Offset(halfW, halfH),
        Offset(-halfW, halfH),
      ])
        canvas.center +
            Offset(
              c.dx * math.cos(a) - c.dy * math.sin(a),
              c.dx * math.sin(a) + c.dy * math.cos(a),
            ),
    ];
  }

  /// Whether the axis-aligned [rect] and the convex [polygon] share any
  /// area: separated along no edge normal of either.
  bool overlapsPolygon(Rect rect, List<Offset> polygon) {
    final box = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    final axes = <Offset>[
      const Offset(1, 0),
      const Offset(0, 1),
      for (var i = 0; i < polygon.length; i++)
        () {
          final edge = polygon[(i + 1) % polygon.length] - polygon[i];
          return Offset(-edge.dy, edge.dx);
        }(),
    ];
    for (final axis in axes) {
      double project(Offset p) => p.dx * axis.dx + p.dy * axis.dy;
      final boxSpan = box.map(project);
      final polySpan = polygon.map(project);
      if (boxSpan.reduce(math.max) <= polySpan.reduce(math.min) ||
          polySpan.reduce(math.max) <= boxSpan.reduce(math.min)) {
        return false;
      }
    }
    return true;
  }

  List<Rect> rectsOf(WidgetTester tester, Finder matching) => [
        for (final element in find
            .descendant(
                of: find.byType(FramingCanvasChrome), matching: matching)
            .evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ];

  void expectApart(List<Rect> rects, String what) {
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].overlaps(rects[j]),
          isFalse,
          reason: '$what ${rects[i]} and ${rects[j]} overlap',
        );
      }
    }
  }

  const sizes = <(String, Size)>[
    ('1600', Size(1600, 1000)),
    ('1280', Size(1280, 800)),
    ('390', Size(390, 844)),
  ];

  for (final (label, size) in sizes) {
    for (final scene in _Scene.values) {
      testWidgets('at $label px with ${scene.name} the chrome stays apart',
          (tester) async {
        final canvas = await pumpScene(tester, size, scene);

        final groups = rectsOf(tester, find.byType(Glass));
        expect(groups, hasLength(4),
            reason: 'target, toolbar, status and zoom, each one glass group');
        expectApart(groups, 'glass groups');
        for (final group in groups) {
          expect(
            canvas.inflate(0.5).contains(group.topLeft) &&
                canvas.inflate(0.5).contains(group.bottomRight),
            isTrue,
            reason: 'group $group runs off the canvas $canvas',
          );
        }

        final controls = [
          ...rectsOf(tester, find.byType(SkotiqIconButton)),
          ...rectsOf(tester, find.byType(SkotiqFilterChip)),
        ];
        expect(controls, hasLength(5),
            reason: 'survey, layers, zoom in, zoom out, fit');
        expectApart(controls, 'controls');

        final frame = reticleCorners(
          canvas,
          scene == _Scene.mosaicRotated ? 30 : 0,
        );
        if (scene != _Scene.noCamera) {
          for (final group in groups) {
            expect(overlapsPolygon(group, frame), isFalse,
                reason: 'group $group covers the camera frame $frame');
          }
        }
      });
    }
  }

  testWidgets(
      'the camera frame is described in the target glass, not on the sky',
      (tester) async {
    await pumpScene(tester, const Size(1280, 800), _Scene.mosaicRotated);
    expect(find.text('Frame 1.00° × 0.76°, rotated 30°'), findsOneWidget);
    expect(find.textContaining('Equipment FOV'), findsNothing);
  });

  testWidgets('without a camera field the target glass says so in one line',
      (tester) async {
    await pumpScene(tester, const Size(1280, 800), _Scene.noCamera);
    expect(
      find.text('Preview 2.0° wide, no camera field set up'),
      findsOneWidget,
    );
    expect(find.text('Configure equipment for accurate framing'), findsNothing);
  });

  testWidgets('the survey chip has room for its whole label', (tester) async {
    await pumpScene(tester, const Size(390, 844), _Scene.target);
    final label = find.descendant(
      of: find.byType(SkotiqFilterChip),
      matching: find.text(SurveySource.dss2Red.displayName),
    );
    final rendered = tester.getRect(label);
    final intrinsic = tester.renderObject<RenderBox>(label);
    expect(
      rendered.width + 0.5,
      greaterThanOrEqualTo(intrinsic.getMinIntrinsicWidth(double.infinity)),
      reason: 'the survey name is narrower than its text and is cut',
    );
  });

  testWidgets('the Layers menu turns every canvas layer on and off',
      (tester) async {
    await pumpScene(tester, const Size(1280, 800), _Scene.target);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FramingCanvas)),
    );

    // The tour prompt's animation never settles, so step the menu's own
    // open and close animations.
    Future<void> pick(String layer) async {
      await tester.tap(find.byTooltip('Layers'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(layer).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await pick('Coordinate grid');
    expect(container.read(framingProvider).showGrid, isTrue);
    await pick('Target label');
    expect(container.read(framingProvider).showLabels, isFalse);
    await pick('Sky directions');
    expect(container.read(framingProvider).showCardinalDirections, isFalse);
    await pick('Guide stars');
    expect(container.read(framingProvider).showGuideStars, isTrue);
    await pick('Crosshair');
    expect(container.read(imagingViewerStateProvider).showCrosshair, isTrue);
  });
}
