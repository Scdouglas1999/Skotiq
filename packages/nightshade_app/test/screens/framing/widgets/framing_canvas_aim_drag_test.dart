// Tests for the "drag the FOV box, sky stays" gesture on [FramingCanvas].
//
// Before this feature every canvas drag called `onPan`, which slid the sky
// under a reticle glued to the canvas center. The gesture now classifies the
// drag by WHERE it starts:
//
//   * on the rotation-handle ring -> rotate (unchanged),
//   * inside the FOV rectangle -> move the AIM on the stationary sky
//     (`onAimChanged` with absolute RA/Dec, projected back through the shared
//     [FramingSkyProjection]),
//   * anywhere else -> pan the sky (`onPan`, unchanged).
//
// Both the ring and the rect anchor to the box's DRAWN center — which leaves
// the canvas center once the reticle is dragged or the sky is panned — so the
// tests exercise the moved-box geometry too, not just the centered case.
//
// Canvas geometry used below (the harness gives the canvas the full 1200x900
// test surface, origin at (0,0), center (600,450)):
//   * synthetic plate scale (no survey image): previewFov 3.0deg over a
//     1333x1000-pixel cutout -> ~399.9 px/deg at zoom 1,
//   * equipment FOV ~1.496deg x ~0.999deg -> ~598px x ~400px rect centered on
//     the box: half-extents ~299px x ~200px,
//   * rotation-handle ring: 200+18 = ~218px from the box center, with a
//     ~40px-wide hit band (handle radius 10 + tolerance 10).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_app/screens/framing/widgets/framing_canvas.dart';
import 'package:nightshade_app/screens/framing/painters/framing_background_painters.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_ui/nightshade_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A camera + scope giving a roughly 1.5° x 1.0° field, so the drawn FOV rect
/// is ~598px x ~400px on the 1200x900 test canvas at ~400 px/deg.
const _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 23.5,
  sensorHeightMm: 15.7,
  pixelSizeMicrons: 3.76,
  pixelsX: 6248,
  pixelsY: 4176,
  telescopeName: 'Test Scope',
  focalLengthMm: 900,
  apertureMm: 150,
);

const _equipmentResult = FramingEquipmentResult(
  status: EquipmentStatus.ready,
  equipment: _equipment,
  profileName: 'Test Profile',
);

const _target = FramingTarget(
  name: 'M45',
  raHours: 5.0,
  decDegrees: 20.0,
  type: TargetType.cluster,
);

// Recorded callbacks, per pump.
class _Calls {
  final pans = <(double, double, Size)>[];
  final rotates = <double>[];
  final aims = <(double, double)>[];
}

Future<ProviderContainer> _pumpCanvas(
  WidgetTester tester, {
  required FramingState framingState,
  required _Calls calls,
  FramingEquipmentResult? equipmentResult = _equipmentResult,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      // Keep the GPU HiPS tile layer inert: no real properties fetch/network.
      hipsFramingEnabledProvider.overrideWith((ref) => false),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: NightshadeTheme.dark,
        home: Scaffold(
          body: FramingCanvas(
            colors: NightshadeColors.dark,
            framingState: framingState,
            equipmentResult: equipmentResult,
            onPan: (dx, dy, size) => calls.pans.add((dx, dy, size)),
            onRotate: (angle) => calls.rotates.add(angle),
            // Mirror the screen's wiring so the assertions can also check the
            // provider-visible invariant (pan/target untouched by a box drag).
            onAimChanged: (ra, dec) {
              calls.aims.add((ra, dec));
              container.read(framingProvider.notifier).setAim(ra, dec);
            },
            onCanvasResized: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('crosshair starts hidden and can be enabled from framing',
      (tester) async {
    final container = await _pumpCanvas(tester,
        framingState: const FramingState(target: _target), calls: _Calls());
    final crosshair = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is FramingCrosshairPainter);
    expect(crosshair, findsNothing);
    expect(container.read(imagingViewerStateProvider).showCrosshair, isFalse);
    await tester.tap(find.byTooltip('Crosshair'));
    await tester.pump();
    expect(crosshair, findsOneWidget);
    expect(container.read(imagingViewerStateProvider).showCrosshair, isTrue);
  });

  testWidgets('drag inside the FOV rect moves the aim, not the sky', (
    tester,
  ) async {
    final calls = _Calls();
    final container = await _pumpCanvas(
      tester,
      framingState: const FramingState(
        target: _target,
        previewFovDegrees: 3.0,
      ),
      calls: calls,
    );

    // Canvas center is inside the box (box is centered while the aim is unset).
    await tester.dragFrom(const Offset(600, 450), const Offset(50, 30));
    await tester.pump();

    expect(calls.pans, isEmpty, reason: 'inside drag must not pan the sky');
    expect(calls.rotates, isEmpty);
    expect(calls.aims, isNotEmpty);

    // Expected aim: the sky point 50px right / 30px down of the view center at
    // ~399.9 px/deg. +x is increasing RA (folded by cos(20deg)), +y is
    // decreasing Dec.
    const ppd = 399.9; // 1199.7 drawn px / 3.0 deg
    const expectedRa =
        5.0 + (50 / ppd) / (15.0 * 0.9396926207859084 /* cos(20deg) */);
    const expectedDec = 20.0 - (30 / ppd);
    final (aimRa, aimDec) = calls.aims.last;
    expect(aimRa, closeTo(expectedRa, 1e-3));
    expect(aimDec, closeTo(expectedDec, 1e-3));

    // The provider-visible invariant: the view centre (target) and the pan
    // transform are untouched — the sky did not move.
    final state = container.read(framingProvider);
    expect(state.panX, 0);
    expect(state.panY, 0);
    expect(state.target, isNull); // widget prop only; provider never targeted
    expect(state.aimRaHours, closeTo(expectedRa, 1e-3));
    expect(state.aimDecDegrees, closeTo(expectedDec, 1e-3));
  });

  testWidgets('grab offset keeps the grabbed spot under the cursor', (
    tester,
  ) async {
    final calls = _Calls();
    await _pumpCanvas(
      tester,
      framingState: const FramingState(
        target: _target,
        previewFovDegrees: 3.0,
      ),
      calls: calls,
    );

    // Grab 150px right of the box center (inside the ~299px half-width, and
    // inside the ~198px inner radius of the rotation ring so it is NOT
    // classified as a rotate), then move 40px further right. Without the grab
    // offset the box center would snap to the pointer; with it the aim must
    // land at the sky point 40px right of the view center — the dragged spot
    // minus the grab.
    await tester.dragFrom(const Offset(750, 450), const Offset(40, 0));
    await tester.pump();

    expect(calls.pans, isEmpty);
    expect(calls.aims, isNotEmpty);
    const ppd = 399.9;
    const expectedRa = 5.0 + (40 / ppd) / (15.0 * 0.9396926207859084);
    expect(calls.aims.last.$1, closeTo(expectedRa, 1e-3));
    expect(calls.aims.last.$2, closeTo(20.0, 1e-3));
  });

  testWidgets('drag outside the FOV rect pans the sky as before', (
    tester,
  ) async {
    final calls = _Calls();
    await _pumpCanvas(
      tester,
      framingState: const FramingState(
        target: _target,
        previewFovDegrees: 3.0,
      ),
      calls: calls,
    );

    // (200,100) is ~531px from the box center: outside both the rect and the
    // rotation ring -> plain sky pan.
    await tester.dragFrom(const Offset(200, 100), const Offset(30, 10));
    await tester.pump();

    expect(calls.aims, isEmpty, reason: 'outside drag must not move the aim');
    expect(calls.rotates, isEmpty);
    expect(calls.pans, isNotEmpty);
    // The reported deltas accumulate to the full drag — exactly what
    // FramingNotifier.pan consumes. (Slop folding can split the raw offset
    // across updates, so the sum is the stable assertion.)
    final totalDx = calls.pans.fold<double>(0, (sum, c) => sum + c.$1);
    final totalDy = calls.pans.fold<double>(0, (sum, c) => sum + c.$2);
    expect(totalDx, closeTo(30, 1e-6));
    expect(totalDy, closeTo(10, 1e-6));
    expect(calls.pans.last.$3, const Size(1200, 900));
  });

  testWidgets('drag on the rotation ring still rotates', (tester) async {
    final calls = _Calls();
    await _pumpCanvas(
      tester,
      framingState: const FramingState(
        target: _target,
        previewFovDegrees: 3.0,
      ),
      calls: calls,
    );

    // ~218px above the box center: on the handle ring, outside the ~200px
    // rect half-height.
    await tester.dragFrom(const Offset(600, 232), const Offset(60, 0));
    await tester.pump();

    expect(calls.pans, isEmpty);
    expect(calls.aims, isEmpty);
    expect(calls.rotates, isNotEmpty);
    // atan2(60, 218) ≈ 15.4deg of handle travel about the box center.
    expect(calls.rotates.last, closeTo(15.4, 0.5));
  });

  group('moved box (aim already off-center)', () {
    // Aim dragged 0.6deg north: u = (0, -0.6*~400) = (0,-240) -> the drawn box
    // sits at (600,210), so the canvas center (600,450) is OUTSIDE it.
    const movedState = FramingState(
      target: _target,
      previewFovDegrees: 3.0,
      aimRaHours: 5.0,
      aimDecDegrees: 20.6,
    );

    testWidgets(
        'drag at the old canvas center pans — hit-testing follows the '
        'box', (tester) async {
      final calls = _Calls();
      await _pumpCanvas(tester, framingState: movedState, calls: calls);

      // Canvas center is 240px below the moved box: beyond the ~200px rect
      // half-height AND beyond the ~238px ring outer radius -> sky pan.
      await tester.dragFrom(const Offset(600, 450), const Offset(30, 0));
      await tester.pump();

      expect(calls.aims, isEmpty);
      expect(calls.rotates, isEmpty);
      expect(calls.pans, isNotEmpty);
    });

    testWidgets('drag inside the moved box still moves the aim', (
      tester,
    ) async {
      final calls = _Calls();
      await _pumpCanvas(tester, framingState: movedState, calls: calls);

      // The moved box center is (600,210): inside the rect there.
      await tester.dragFrom(const Offset(600, 210), const Offset(40, 0));
      await tester.pump();

      expect(calls.pans, isEmpty);
      expect(calls.aims, isNotEmpty);
      const ppd = 399.9;
      // 40px right -> +40/ppd deg of RA folded by cos(dec); Dec unchanged at
      // the dragged aim's 20.6 (a horizontal drag moves along a parallel).
      const expectedRa = 5.0 + (40 / ppd) / (15.0 * 0.9396926207859084);
      expect(calls.aims.last.$1, closeTo(expectedRa, 1e-3));
      expect(calls.aims.last.$2, closeTo(20.6, 1e-3));
    });

    testWidgets('rotation ring is hit-tested around the moved box', (
      tester,
    ) async {
      final calls = _Calls();
      await _pumpCanvas(tester, framingState: movedState, calls: calls);

      // 218px to the right of the moved box center (600,210): inside the
      // ring's hit band, so this rotates about the MOVED box.
      await tester.dragFrom(const Offset(818, 210), const Offset(0, 60));
      await tester.pump();

      expect(calls.pans, isEmpty);
      expect(calls.aims, isEmpty);
      expect(calls.rotates, isNotEmpty);
      // atan2(218, -60) ≈ 105.4deg of handle travel about the moved box center.
      expect(calls.rotates.last, closeTo(105.4, 0.8));
    });
  });

  testWidgets('no box drag without a framed target', (tester) async {
    final calls = _Calls();
    await _pumpCanvas(
      tester,
      // Equipment but no target: there is no aim to move, so every non-ring
      // drag must remain a sky pan.
      framingState: const FramingState(previewFovDegrees: 3.0),
      calls: calls,
    );

    await tester.dragFrom(const Offset(600, 450), const Offset(50, 30));
    await tester.pump();

    expect(calls.aims, isEmpty);
    expect(calls.pans, isNotEmpty);
  });

  testWidgets('no box drag without equipment', (tester) async {
    final calls = _Calls();
    await _pumpCanvas(
      tester,
      framingState: const FramingState(
        target: _target,
        previewFovDegrees: 3.0,
      ),
      equipmentResult: null,
      calls: calls,
    );

    await tester.dragFrom(const Offset(600, 450), const Offset(50, 30));
    await tester.pump();

    expect(calls.aims, isEmpty);
    expect(calls.pans, isNotEmpty);
  });
}
