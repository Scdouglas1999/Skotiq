// Mouse-wheel zoom compounds.
//
// Restarting the 300 ms zoom glide from the LIVE field of view on every notch
// makes two notches 50 ms apart both start from ~60 deg, so the second throws
// away the first one's progress: 20 notches at 50 ms spacing move the FOV
// 60.0 -> 50.0 — the effect of one notch out of twenty — and it takes 172
// notches to reach an imaging field.
//
// The assertion below is the compounding property: N rapid notches equal N
// notches, whatever the spacing.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/providers/deep_star_providers.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

/// Same step ladder the view uses: coarse above 30 deg, fine at or below.
double _expectedAfterNotches(double startFov, int notches) {
  var fov = startFov;
  for (var i = 0; i < notches; i++) {
    fov = fov / (fov > 30 ? 1.2 : 1.15);
  }
  return fov;
}

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
      child: const MaterialApp(home: Scaffold(body: InteractiveSkyView())),
    ),
  );
  await tester.pump();
  return container;
}

/// Drive [notches] real wheel events through the widget's own pointer-signal
/// handler, [gap] apart. Going through `sendEventToBinding` keeps the
/// production Listener wiring in the loop — cutting it fails this test.
Future<void> _spinWheelIn(
  WidgetTester tester, {
  required int notches,
  required Duration gap,
}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  final location = tester.getCenter(find.byType(InteractiveSkyView));
  await tester.sendEventToBinding(pointer.hover(location));
  for (var i = 0; i < notches; i++) {
    // Negative dy = scroll up = zoom in.
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    // Two frames: the zero-duration one starts the freshly restarted zoom
    // ticker (its first tick always reports elapsed 0), the second actually
    // advances the glide by [gap]. Without the second frame the animation
    // never moves and "slow" notches would be indistinguishable from fast
    // ones — the very thing under test.
    await tester.pump();
    await tester.pump(gap);
  }
  // Let the last glide finish.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'rapid wheel notches compound: 10 notches 20ms apart zoom as far as '
    '10 notches do',
    (tester) async {
      final container = await _pumpSkyView(tester);
      expect(container.read(skyViewStateProvider).fieldOfView, 60.0);

      await _spinWheelIn(
        tester,
        notches: 10,
        gap: const Duration(milliseconds: 20),
      );

      final expected = _expectedAfterNotches(60.0, 10);
      expect(expected, lessThan(13.0)); // guards the ladder above
      expect(
        container.read(skyViewStateProvider).fieldOfView,
        closeTo(expected, 0.01),
        reason: 'fast notches must not be discarded by the in-flight glide',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets('spacing does not change where the wheel lands', (tester) async {
    final fast = await _pumpSkyView(tester);
    await _spinWheelIn(
      tester,
      notches: 6,
      gap: const Duration(milliseconds: 16),
    );
    final fastFov = fast.read(skyViewStateProvider).fieldOfView;
    await tester.pumpWidget(const SizedBox.shrink());
    fast.dispose();

    final slow = await _pumpSkyView(tester);
    await _spinWheelIn(
      tester,
      notches: 6,
      gap: const Duration(milliseconds: 500),
    );
    final slowFov = slow.read(skyViewStateProvider).fieldOfView;
    await tester.pumpWidget(const SizedBox.shrink());
    slow.dispose();

    expect(fastFov, closeTo(slowFov, 0.01));
  });
}
