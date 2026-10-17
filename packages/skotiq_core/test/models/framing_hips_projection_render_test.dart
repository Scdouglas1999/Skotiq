// Tagged "golden" so the perceptual/pixel-diff golden gate is excluded by
// `melos run test` (Linux CI + default local runs) and opt-in via
// `melos run test:golden`. Baselines are host-specific; see
// docs/testing/golden-tests.md.
@Tags(['golden'])
library;

// Visual verification + golden for the shared framing sky<->screen projection.
//
// [FramingSkyProjection] is pure math, but its whole job is to register sky
// coordinates with the framing render path's pixel geometry. This test *renders*
// that registration so it can be eyeballed and locked as a golden:
//
//   1. It draws a synthetic survey background into the exact draw rect the
//      framing background painter uses (`FramingPlateScale.drawRectFor`).
//   2. It overlays an RA/Dec graticule whose every node is placed via
//      [FramingSkyProjection.raDecToScreen]. If the projection is registered to
//      the plate scale, the graticule lines stay parallel to the survey image
//      edges and the central node sits exactly on the target.
//   3. It draws the equipment FOV reticle the same way the framing FOV overlay
//      does (centered, sized by `pixelsPerDegree`) so registration of the
//      overlay against the projected grid is visible.
//   4. It marks the four `visibleSkyCorners()` round-tripped back to screen,
//      which must land on the canvas corners — proving forward/inverse agree.
//
// The PNG is written both to a `.hips_verify/` sample (printed as an absolute
// path) and compared against a checked-in golden. Regenerate the golden with
//   flutter test --update-goldens test/models/framing_hips_projection_render_test.dart
// Goldens render with the default test font on the running toolchain (the repo
// convention — no golden_toolkit / font loading), so regenerate on the same
// toolchain that verifies.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/framing_hips_projection.dart';
import 'package:skotiq_core/src/models/framing_plate_scale.dart';

const _canvasSize = Size(1280, 800);

// A 3deg-wide, 1.875deg-tall survey cutout matching the canvas aspect (1.6),
// 1600x1000 px — the shape the framing path produces for a fit-to-canvas cutout.
const _plateScale = FramingPlateScale(
  surveyFovWidthDeg: 3.0,
  surveyFovHeightDeg: 1.875,
  imagePixelWidth: 1600,
  imagePixelHeight: 1000,
);

const _centerRaHours = 5.5; // ~Orion's belt region
const _centerDecDegrees = -2.0;
const _zoom = 1.0;
const _pan = Offset(60, -30);
const _rotationDegrees = 12.0;

// Equipment FOV (degrees) for the reticle.
const _fovWidthDeg = 1.2;
const _fovHeightDeg = 0.9;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'renders projection registration golden + .hips_verify sample',
    () async {
      final view = FramingProjectionView(
        plateScale: _plateScale,
        previewFovDegrees: _plateScale.surveyFovWidthDeg,
        centerRaHours: _centerRaHours,
        centerDecDegrees: _centerDecDegrees,
        zoom: _zoom,
        panX: _pan.dx,
        panY: _pan.dy,
        rotationDegrees: _rotationDegrees,
      );
      final proj = FramingSkyProjection.fromView(_canvasSize, view);

      final image = await _renderRegistration(proj);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);
      final pngBytes = bytes!.buffer.asUint8List();

      // 1) Write the human-inspectable sample artifact and print its path.
      final repoRoot = _findRepoRoot();
      final verifyDir = Directory('${repoRoot.path}/.hips_verify');
      if (!verifyDir.existsSync()) {
        verifyDir.createSync(recursive: true);
      }
      final samplePath =
          '${verifyDir.path}/framing_hips_projection_registration.png';
      File(samplePath).writeAsBytesSync(pngBytes, flush: true);
      // ignore: avoid_print
      print('HIPS_VERIFY_SAMPLE: $samplePath');

      // 2) Lock the rendering as a golden. matchesGoldenFile accepts a
      //    Future<List<int>> of PNG bytes directly.
      await expectLater(
        Future<List<int>>.value(pngBytes),
        matchesGoldenFile('goldens/framing_hips_projection_registration.png'),
      );

      image.dispose();
    },
  );
}

/// Render: survey background draw rect + projected RA/Dec graticule + FOV
/// reticle + corner round-trip markers.
Future<ui.Image> _renderRegistration(FramingSkyProjection proj) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, _canvasSize.width, _canvasSize.height),
  );

  // Backdrop.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, _canvasSize.width, _canvasSize.height),
    Paint()..color = const Color(0xFF05070C),
  );

  // 1) Survey background, rotated about canvas center exactly like
  //    FramingSurveyImagePainter.
  final destRect = _plateScale.drawRectFor(_canvasSize, _zoom, _pan);
  final pivot = Offset(_canvasSize.width / 2, _canvasSize.height / 2);
  canvas.save();
  canvas.translate(pivot.dx, pivot.dy);
  canvas.rotate(_rotationDegrees * math.pi / 180);
  canvas.translate(-pivot.dx, -pivot.dy);
  // Synthetic "survey" fill: a gradient + diagonal hatching so rotation is
  // visible, drawn into the exact dest rect.
  final surveyPaint = Paint()
    ..shader = const LinearGradient(
      colors: [Color(0xFF15233B), Color(0xFF2A1530)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(destRect);
  canvas.drawRect(destRect, surveyPaint);
  final hatch = Paint()
    ..color = const Color(0x22FFFFFF)
    ..strokeWidth = 1.0;
  for (double x = destRect.left; x <= destRect.right; x += 48) {
    canvas.drawLine(Offset(x, destRect.top), Offset(x, destRect.bottom), hatch);
  }
  for (double y = destRect.top; y <= destRect.bottom; y += 48) {
    canvas.drawLine(Offset(destRect.left, y), Offset(destRect.right, y), hatch);
  }
  canvas.restore();

  // 2) Projected RA/Dec graticule. Nodes every 0.5deg in Dec and 2min in RA
  //    across the survey field, projected with FramingSkyProjection.
  final gridPaint = Paint()
    ..color = const Color(0x6655E0C0)
    ..strokeWidth = 1.2
    ..style = PaintingStyle.stroke;
  const decStartDeg = _centerDecDegrees - 1.2;
  const decEndDeg = _centerDecDegrees + 1.2;
  const raStartHours = _centerRaHours - 0.13;
  const raEndHours = _centerRaHours + 0.13;
  const decStep = 0.3;
  const raStep = 0.03; // hours

  // Lines of constant Dec.
  for (double dec = decStartDeg; dec <= decEndDeg + 1e-9; dec += decStep) {
    final path = Path();
    var first = true;
    for (double ra = raStartHours; ra <= raEndHours + 1e-9; ra += raStep / 4) {
      final p = proj.raDecToScreen(ra, dec);
      if (first) {
        path.moveTo(p.dx, p.dy);
        first = false;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, gridPaint);
  }
  // Lines of constant RA.
  for (double ra = raStartHours; ra <= raEndHours + 1e-9; ra += raStep) {
    final path = Path();
    var first = true;
    for (
      double dec = decStartDeg;
      dec <= decEndDeg + 1e-9;
      dec += decStep / 4
    ) {
      final p = proj.raDecToScreen(ra, dec);
      if (first) {
        path.moveTo(p.dx, p.dy);
        first = false;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, gridPaint);
  }

  // 3) Target marker at the exact center sky coordinate.
  final center = proj.raDecToScreen(_centerRaHours, _centerDecDegrees);
  canvas.drawCircle(center, 6, Paint()..color = const Color(0xFFFFD166));
  canvas.drawCircle(
    center,
    10,
    Paint()
      ..color = const Color(0xFFFFD166)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5,
  );

  // 4) FOV reticle: corners projected from the target +/- half-FOV in sky.
  final halfRaHours =
      (_fovWidthDeg / 2) / math.cos(_centerDecDegrees * math.pi / 180) / 15.0;
  const halfDecDeg = _fovHeightDeg / 2;
  final fovCorners = <Offset>[
    proj.raDecToScreen(
      _centerRaHours - halfRaHours,
      _centerDecDegrees + halfDecDeg,
    ),
    proj.raDecToScreen(
      _centerRaHours + halfRaHours,
      _centerDecDegrees + halfDecDeg,
    ),
    proj.raDecToScreen(
      _centerRaHours + halfRaHours,
      _centerDecDegrees - halfDecDeg,
    ),
    proj.raDecToScreen(
      _centerRaHours - halfRaHours,
      _centerDecDegrees - halfDecDeg,
    ),
  ];
  final fovPath = Path()..addPolygon(fovCorners, true);
  canvas.drawPath(
    fovPath,
    Paint()
      ..color = const Color(0xFFFF6B6B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5,
  );

  // 5) Corner round-trip markers: project each canvas corner -> sky -> screen.
  //    They must land back on the canvas corners (forward/inverse agreement).
  final cornerPaint = Paint()..color = const Color(0xFF6FB1FF);
  for (final sky in proj.visibleSkyCorners()) {
    final back = proj.raDecToScreen(sky.raHours, sky.decDegrees);
    canvas.drawCircle(back, 7, cornerPaint);
  }

  final picture = recorder.endRecording();
  return picture.toImage(_canvasSize.width.round(), _canvasSize.height.round());
}

/// Walk up from the test's working directory to the monorepo root (the dir that
/// contains `version.yaml`).
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/version.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Fallback: skotiq_core's known relative position is <root>/packages/...
  return Directory.current.parent.parent;
}
