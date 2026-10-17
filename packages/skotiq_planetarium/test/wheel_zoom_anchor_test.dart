// The mouse wheel zooms toward the cursor.
//
// Zooming about the view centre instead: with the pointer parked well
// off-centre, 23 wheel-up notches take the field of view from 60.0 deg to
// 2.0 deg while `Center RA: 0h 42m 44s / Center Dec: +41 deg 16'` stays
// BYTE-IDENTICAL. Whatever the cursor is over — the object being aimed at — is
// thrown off screen and has to be dragged back after every step.
//
// The property under test is the one every map UI has (and Stellarium and
// SkySafari): the sky under the pointer does not move.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/providers/deep_star_providers.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

const Size _canvas = Size(800, 600);

Future<ProviderContainer> _pumpSkyView(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      combinedStarsProvider.overrideWithValue(const AsyncValue.data(<Star>[])),
      fovFilteredDsosProvider.overrideWithValue(
        const AsyncValue.data(<DeepSkyObject>[]),
      ),
    ],
  );
  // The sky is drawn from the observer's site; without one the view renders
  // its no-site state instead.
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: 40.0, longitude: -74.0);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: _canvas.width,
              height: _canvas.height,
              child: const InteractiveSkyView(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Where [coord] is drawn, in the sky view's own coordinates, using the same
/// projector the painter and the hit-tester use.
Offset? _screenPositionOf(ProviderContainer container, CelestialCoordinate c) {
  final projector = SkyFovProjector.forSize(
    container.read(skyViewStateProvider),
    _canvas,
    latitude: container.read(observerLocationProvider).site!.latitude,
  );
  return projector.project(c);
}

/// The sky under [local] right now.
CelestialCoordinate? _skyUnder(ProviderContainer container, Offset local) {
  final projector = SkyFovProjector.forSize(
    container.read(skyViewStateProvider),
    _canvas,
    latitude: container.read(observerLocationProvider).site!.latitude,
  );
  return projector.unproject(local);
}

Future<void> _spinWheel(
  WidgetTester tester, {
  required Offset at,
  required int notches,
}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  final topLeft = tester.getTopLeft(find.byType(InteractiveSkyView));
  await tester.sendEventToBinding(pointer.hover(topLeft + at));
  for (var i = 0; i < notches; i++) {
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the sky under the cursor stays under the cursor', (
    tester,
  ) async {
    final container = await _pumpSkyView(tester);
    container
        .read(skyViewStateProvider.notifier)
        .setCenter(0.712, 41.27); // M31, the field the live drive was on
    await tester.pump();

    // Well off-centre: a quarter of the canvas up and to the left, which is
    // where the live drive had its pointer.
    const cursor = Offset(230, 170);
    final anchor = _skyUnder(container, cursor)!;
    final startFov = container.read(skyViewStateProvider).fieldOfView;

    await _spinWheel(tester, at: cursor, notches: 8);

    final endFov = container.read(skyViewStateProvider).fieldOfView;
    expect(endFov, lessThan(startFov / 2), reason: 'the wheel did zoom');

    final landed = _screenPositionOf(container, anchor);
    expect(landed, isNotNull, reason: 'the anchor is still on screen');
    expect(
      (landed! - cursor).distance,
      lessThan(4.0),
      reason: 'zooming in threw the object under the pointer off screen',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('an off-centre wheel zoom moves the view centre', (tester) async {
    final container = await _pumpSkyView(tester);
    container.read(skyViewStateProvider.notifier).setCenter(0.712, 41.27);
    await tester.pump();
    final startRa = container.read(skyViewStateProvider).centerRA;
    final startDec = container.read(skyViewStateProvider).centerDec;

    await _spinWheel(tester, at: const Offset(230, 170), notches: 8);

    final state = container.read(skyViewStateProvider);
    // The live evidence was a centre that stayed byte-identical through 23
    // notches; anything anchored on the cursor must move it.
    expect(
      (state.centerRA - startRa).abs() + (state.centerDec - startDec).abs(),
      greaterThan(0.01),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('zooming with the cursor at the centre holds the centre', (
    tester,
  ) async {
    final container = await _pumpSkyView(tester);
    container.read(skyViewStateProvider.notifier).setCenter(0.712, 41.27);
    await tester.pump();
    final startRa = container.read(skyViewStateProvider).centerRA;
    final startDec = container.read(skyViewStateProvider).centerDec;

    await _spinWheel(
      tester,
      at: Offset(_canvas.width / 2, _canvas.height / 2),
      notches: 6,
    );

    final state = container.read(skyViewStateProvider);
    expect(state.centerRA, closeTo(startRa, 0.001));
    expect(state.centerDec, closeTo(startDec, 0.01));
    expect(state.fieldOfView, lessThan(30.0));

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
