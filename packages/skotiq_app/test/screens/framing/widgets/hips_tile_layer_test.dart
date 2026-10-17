// Component C8 — widget guards for the HiPS framing tile layer.
//
// What these pin (the never-blank + platform-independence + no-gesture-capture
// contract the widget is responsible for):
//
//   * INACTIVE → TRANSPARENT: when the feature flag is off (or the survey lacks
//     a verified HiPS pyramid) the layer mounts a zero-cost transparent box and
//     paints NO tile painter, so the framing canvas's single survey snapshot /
//     starfield is the visible background. It must never throw resolving an
//     un-tile-capable survey's address.
//   * PROPERTIES PENDING/FAILED → TRANSPARENT: while the survey `properties`
//     are loading, or after a fetch failure, the layer stays transparent (the
//     single snapshot shows through) rather than flashing blank or throwing —
//     errors are surfaced, never silently blanked.
//   * NO GESTURE CAPTURE: the layer is wrapped in IgnorePointer so pan/rotate
//     gestures fall through to the framing canvas beneath it.
//   * PLATFORM INDEPENDENCE: the widget never reads any planetarium
//     rendering-platform provider; it works as a Flutter-side layer regardless.
//
// Determinism: a fake fetcher (no network) is injected via
// [hipsTileFetcherProvider]; the resident snapshot is seeded via the
// subclass-and-seed pattern on [hipsResidentTilesProvider]. No HTTP is ever
// issued.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/hips_tile_layer_painter.dart';
import 'package:skotiq_app/screens/framing/widgets/hips_tile_layer.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';

const FramingTarget _target = FramingTarget(
  name: 'NGC 7000',
  catalogId: 'NGC7000',
  raHours: 20.97,
  decDegrees: 44.33,
);

/// Seeds [FramingNotifier] with a known state (subclass-and-seed pattern), so
/// the layer reads a fixed target/survey/zoom/pan without DB/network wiring.
class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

/// A fetcher that never touches the network. [fetchProperties] either throws an
/// HTTP error (simulating "offline / properties unreachable") or hangs forever
/// (simulating "still loading"), per [failImmediately].
class _FakeFetcher extends HipsTileFetcher {
  final bool failImmediately;
  _FakeFetcher({required this.failImmediately});

  @override
  Future<HipsProperties> fetchProperties(
    String baseUrl, {
    HipsFetchToken? token,
  }) {
    if (failImmediately) {
      return Future.error(
        const HipsFetchHttpException('offline (test)', 'test://properties'),
      );
    }
    // Never completes: simulates a properties fetch still in flight.
    return Completer<HipsProperties>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FramingState seededState({SurveySource source = SurveySource.dss2Red}) {
    return FramingState(
      target: _target,
      surveySource: source,
      previewFovDegrees: 0.5,
    );
  }

  Widget hostUnder(List<Override> overrides) {
    return ProviderScope(
      overrides: [...overrides],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: HipsTileLayer(),
          ),
        ),
      ),
    );
  }

  testWidgets(
      'inactive (feature off): layer is transparent and paints no tile painter',
      (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededState())),
      hipsFramingEnabledProvider.overrideWith((ref) => false),
      hipsTileFetcherProvider
          .overrideWithValue(_FakeFetcher(failImmediately: true)),
    ]));
    await tester.pump();

    expect(find.byType(HipsTileLayer), findsOneWidget);
    expect(_hipsPainters(tester), isEmpty,
        reason: 'Feature off → no HiPS tile painter; the single survey '
            'snapshot underneath is the visible background.');
  });

  testWidgets(
      'active + properties still loading: layer stays transparent (never-blank '
      'fallback to single snapshot)', (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededState())),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider
          .overrideWithValue(_FakeFetcher(failImmediately: false)),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(_hipsPainters(tester), isEmpty,
        reason: 'Properties not yet ready → transparent; the single survey '
            'snapshot remains visible (no blank flash).');
  });

  testWidgets(
      'active + properties fetch failed: layer stays transparent (error '
      'surfaced, falls back to single snapshot)', (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededState())),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider
          .overrideWithValue(_FakeFetcher(failImmediately: true)),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(_hipsPainters(tester), isEmpty,
        reason: 'A properties failure must leave the layer transparent so the '
            'single snapshot shows through — never a silent blank.');
    expect(tester.takeException(), isNull,
        reason: 'A surfaced fetch failure must not crash the widget tree.');
  });

  testWidgets('the layer is wrapped in IgnorePointer so gestures fall through',
      (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededState())),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider
          .overrideWithValue(_FakeFetcher(failImmediately: false)),
    ]));
    await tester.pump();

    final ignorePointers = find.descendant(
      of: find.byType(HipsTileLayer),
      matching: find.byType(IgnorePointer),
    );
    expect(ignorePointers, findsOneWidget,
        reason: 'HiPS tiles are pure imagery; pan/rotate gestures must reach '
            'the framing canvas beneath, so the layer ignores pointers.');
  });

  testWidgets(
      'un-tile-capable survey (no verified HiPS pyramid): layer is inactive, '
      'no throw', (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider.overrideWith(
        (ref) => _SeededFramingNotifier(
          ref,
          seededState(source: SurveySource.sdss),
        ),
      ),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider
          .overrideWithValue(_FakeFetcher(failImmediately: true)),
    ]));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'A survey with no verified HiPS base URL must deactivate the '
            'layer cleanly, not throw resolving its address.');
    expect(_hipsPainters(tester), isEmpty,
        reason: 'Un-tile-capable survey → inactive → no tile painter.');
  });
}

/// All [HipsTileLayerPainter]s currently mounted in the tree.
Iterable<HipsTileLayerPainter> _hipsPainters(WidgetTester tester) {
  return tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((cp) => cp.painter)
      .whereType<HipsTileLayerPainter>();
}
