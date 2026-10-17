import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

Widget _host(
  void Function(WidgetRef) capture, {
  double centerRaHours = 6.0,
  double centerDecDeg = 0.0,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            capture(ref);
            return SizedBox(
              width: 400,
              height: 400,
              child: MultiFovOverlay(
                centerRaHours: centerRaHours,
                centerDecDeg: centerDecDeg,
                fieldOfViewDeg: 10.0,
                viewRotationDeg: 0.0,
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Screen rect of the active preset's interactive region, which is centered on
/// wherever the overlay projected that preset.
Rect _activeRegion(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(MultiFovOverlay),
    matching: find.byType(GestureDetector),
  ),
);

const _wideRig = FovPreset(
  id: 'a',
  name: 'Wide',
  focalLengthMm: 480,
  sensorWidthMm: 23.5,
  sensorHeightMm: 15.6,
  pixelSizeMicrons: 3.9,
);

void main() {
  testWidgets('renders nothing interactive when no presets exist', (
    tester,
  ) async {
    await tester.pumpWidget(_host((_) {}));
    expect(find.byType(MultiFovOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging the active preset body pins it to a sky coordinate', (
    tester,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(_host((ref) => captured = ref));
    captured.read(fovPresetsProvider.notifier).add(_wideRig);
    await tester.pump();

    // Drag from the center of the overlay rightward.
    final center = tester.getCenter(find.byType(MultiFovOverlay));
    await tester.dragFrom(center, const Offset(40, 0));
    await tester.pump();

    final active = captured.read(fovPresetsProvider).active!;
    // Drag pins the preset and shifts the stored center away from the view
    // center. Right on screen is DECREASING RA (the sky view runs RA to the
    // left), so the stored coordinate must move west, not east.
    expect(active.center, isNotNull);
    expect(active.center!.ra, isNot(closeTo(6.0, 1e-6)));
    expect(active.center!.ra, lessThan(6.0));
    // 40 px at 40 px/deg = 1 deg of sky = 1/15 h of RA at dec 0.
    expect(active.center!.ra, closeTo(6.0 - 1 / 15, 0.01));
  });

  testWidgets('a preset pinned EAST of the view center is drawn to its LEFT', (
    tester,
  ) async {
    // Adding the RA offset to x mirrors every rig about the view center — a
    // target 2° east draws 2° west, putting the box an imager frames with on
    // the wrong side of the sky.
    late WidgetRef captured;
    await tester.pumpWidget(_host((ref) => captured = ref));
    final notifier = captured.read(fovPresetsProvider.notifier);
    notifier.add(_wideRig);
    // 2 degrees east of the view center (dec 0, so no cos(dec) foreshortening).
    notifier.setActiveCenter(
      const CelestialCoordinate(ra: 6.0 + 2.0 / 15, dec: 0),
    );
    await tester.pump();

    final viewCenter = tester.getCenter(find.byType(MultiFovOverlay));
    final region = _activeRegion(tester);
    expect(region.center.dx, lessThan(viewCenter.dx));
    // 2 degrees at 40 px/deg.
    expect(viewCenter.dx - region.center.dx, closeTo(80, 2.0));
  });

  testWidgets('a preset near RA 0h stays on screen with the view at 23.9h', (
    tester,
  ) async {
    // The raw RA difference here is -23.7h; scaled straight into pixels it
    // throws the rig thousands of pixels off canvas and every target near the
    // 0h seam loses its FOV box.
    late WidgetRef captured;
    await tester.pumpWidget(
      _host((ref) => captured = ref, centerRaHours: 23.9),
    );
    final notifier = captured.read(fovPresetsProvider.notifier);
    notifier.add(_wideRig);
    notifier.setActiveCenter(const CelestialCoordinate(ra: 0.2, dec: 0));
    await tester.pump();

    final viewCenter = tester.getCenter(find.byType(MultiFovOverlay));
    final region = _activeRegion(tester);
    // 0.3h = 4.5 deg east => 180 px to the LEFT at 40 px/deg.
    expect(viewCenter.dx - region.center.dx, closeTo(180, 4.0));
    expect(region.center.dx, greaterThan(viewCenter.dx - 200));
  });

  testWidgets(
    'dragging lands the rig on the sky coordinate under the pointer',
    (tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(_host((ref) => captured = ref));
      final notifier = captured.read(fovPresetsProvider.notifier);
      notifier.add(_wideRig);
      // 1 deg east and 1 deg north of the view center => drawn 40 px left and
      // 40 px up of the overlay's center at 40 px/deg.
      notifier.setActiveCenter(
        const CelestialCoordinate(ra: 6.0 + 1.0 / 15, dec: 1.0),
      );
      await tester.pump();

      final topLeft = tester.getTopLeft(find.byType(MultiFovOverlay));
      await tester.dragFrom(
        topLeft + const Offset(160, 160),
        const Offset(20, 30),
      );
      await tester.pump();

      // The drag is absolute: the rig must end up on exactly the coordinate the
      // shared projector maps the final pointer position to, so the rectangle
      // tracks the finger instead of sliding away from it.
      const viewState = SkyViewState(
        centerRA: 6,
        centerDec: 0,
        fieldOfView: 10,
      );
      final expected = SkyFovProjector.forSize(
        viewState,
        const Size(400, 400),
      ).unproject(const Offset(180, 190))!;

      final moved = captured.read(fovPresetsProvider).active!.center!;
      expect(moved.ra, closeTo(expected.ra, 1e-9));
      expect(moved.dec, closeTo(expected.dec, 1e-9));
      // Moving right and down is moving west and south on this sky view.
      expect(moved.ra, lessThan(6.0 + 1.0 / 15));
      expect(moved.dec, lessThan(1.0));
    },
  );

  testWidgets('dragging empty sky away from the rig does not pin it '
      '(no gesture hijack)', (tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(_host((ref) => captured = ref));
    captured.read(fovPresetsProvider.notifier).add(_wideRig);
    await tester.pump();

    // A narrow-field rig at view center occupies only the middle of the 400px
    // overlay; the top-left corner is well outside its hit region.
    await tester.dragFrom(const Offset(8, 8), const Offset(30, 30));
    await tester.pump();

    // The preset must stay unpinned: the drag fell through to the sky layer.
    expect(captured.read(fovPresetsProvider).active!.center, isNull);
  });

  testWidgets('dragging the rotation handle changes position angle', (
    tester,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(_host((ref) => captured = ref));
    captured.read(fovPresetsProvider.notifier).add(_wideRig);
    await tester.pump();

    final initialPa = captured
        .read(fovPresetsProvider)
        .active!
        .positionAngleDeg;
    expect(initialPa, 0);

    // The handle sits above the preset center along the short axis.
    final overlayCenter = tester.getCenter(find.byType(MultiFovOverlay));
    final fov = _wideRig.fovDegrees!;
    const scale = 400 / 2 / (10.0 / 2); // min(w,h)/2 / (fov/2)
    final handle = overlayCenter + Offset(0, -(fov.$2 * scale / 2 + 18));

    // Drag the handle sideways to induce a rotation.
    await tester.dragFrom(handle, const Offset(60, 30));
    await tester.pump();

    final pa = captured.read(fovPresetsProvider).active!.positionAngleDeg;
    expect(pa, isNot(0));
  });

  testWidgets('hidden presets are not drawn (overlay collapses)', (
    tester,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(_host((ref) => captured = ref));
    final notifier = captured.read(fovPresetsProvider.notifier);
    notifier.add(_wideRig);
    notifier.toggleVisible('a'); // now hidden
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(captured.read(fovPresetsProvider).active!.visible, isFalse);
  });
}
