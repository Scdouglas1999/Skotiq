// An imaging-scale field that renders empty must say why.
//
// At FOV 1.2 deg on a fresh profile the chart draws 12 star blobs over
// 2.725 sq deg = 4.4 stars/sq deg, against 100-200/sq deg for the real field to
// mag 12 — and 12 of the 13 stars the shipped pack OWNS there. The renderer is
// fine; the catalog is empty past mag 9. StarCatalogFallbackBanner fires solely
// when HYG is missing altogether, so without a second signal the far more common
// "installed but too shallow for this zoom" state passes for a bare patch of
// sky.
//
// No deep tileset is published, so the chart cannot be made deeper from inside
// the app; what it can do is stop presenting a catalog limit as a sky.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/star_chart_depth_notice.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// The slot planetarium_shell.dart gives the notice: pinned top-left of the
/// chart at `(chartWidth - 24)` capped at 460, with free height.
double _slotWidth(double chartWidth) => (chartWidth - 24).clamp(0.0, 460.0);

Future<HarnessHandle> _pumpNotice(
  WidgetTester tester, {
  required double fov,
  DeepStarManifest? manifest,
  bool deepStarsOn = false,
  bool hygMissing = false,
  double chartWidth = 600,
}) async {
  final handle = await pumpAppScreen(
    tester,
    Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: _slotWidth(chartWidth),
        child: const StarChartDepthNotice(),
      ),
    ),
    size: Size(chartWidth, 2000),
    settle: false,
    extraOverrides: [
      deepStarManifestProvider.overrideWith(
        (ref) => Future<DeepStarManifest?>.value(manifest),
      ),
      showDeepStarsProvider.overrideWith((ref) => deepStarsOn),
      starCatalogFallbackProvider.overrideWithValue(hygMissing),
    ],
  );
  handle.container.read(skyViewStateProvider.notifier).setFieldOfView(fov);
  await tester.pump();
  await tester.pump();
  return handle;
}

DeepStarManifest _installed() => const DeepStarManifest(
      name: 'tycho2',
      source: 'test',
      magnitudeFloor: 9.0,
      magnitudeLimit: 12.0,
      tiles: [],
    );

void main() {
  testWidgets('an imaging-scale field says the catalog, not the sky, is empty',
      (tester) async {
    await _pumpNotice(tester, fov: 1.2);

    expect(find.text('Chart is shallower than the sky'), findsOneWidget);
    expect(
      find.textContaining('magnitude 9.0'),
      findsOneWidget,
      reason: 'the number is the whole point — a user has to be able to tell '
          'a missing star from an absent one',
    );
    // Nothing can be INSTALLED from here: the action opens the Catalog Settings
    // form, which the Layers panel row calls "Configure source…". This alert is
    // raised the moment a user zooms to an imaging field, when they most believe
    // the missing stars are one click away, so it must not promise an install.
    expect(find.text('Install'), findsNothing);
    expect(find.text('Configure'), findsOneWidget);
    expect(
      find.textContaining('No deep-star tileset is published'),
      findsOneWidget,
      reason: 'say why the sky is empty instead of implying a download',
    );
  });

  // The alert lays its action out in a Row beside the message, so a longer
  // label eats the message column and the block grows tall enough to cover the
  // chart it annotates. Budgets: 225 px at the 460 px slot cap, 393 px in a
  // 360 px phone chart.
  testWidgets('the honest label does not cost the message its column',
      (tester) async {
    await _pumpNotice(tester, fov: 1.2, chartWidth: 484);
    expect(tester.getSize(find.byType(SkotiqAlert)).height, lessThan(250));
  });

  testWidgets('...nor in a phone-width chart', (tester) async {
    await _pumpNotice(tester, fov: 1.2, chartWidth: 360);
    expect(tester.getSize(find.byType(SkotiqAlert)).height, lessThan(400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide field says nothing', (tester) async {
    await _pumpNotice(tester, fov: 40.0);

    expect(find.text('Chart is shallower than the sky'), findsNothing);
  });

  testWidgets('with the tier installed but off, it offers to turn it on',
      (tester) async {
    final handle = await _pumpNotice(
      tester,
      fov: 1.2,
      manifest: _installed(),
    );

    expect(find.text('Chart is shallower than the sky'), findsOneWidget);
    expect(find.text('Enable'), findsOneWidget);

    await tester.tap(find.text('Enable'));
    await tester.pump();

    expect(handle.container.read(showDeepStarsProvider), isTrue);
  });

  testWidgets('with the tier installed and on, the chart is as deep as it gets',
      (tester) async {
    await _pumpNotice(
      tester,
      fov: 1.2,
      manifest: _installed(),
      deepStarsOn: true,
    );

    expect(find.text('Chart is shallower than the sky'), findsNothing);
  });

  testWidgets('the louder "no catalog at all" banner is not doubled up',
      (tester) async {
    await _pumpNotice(tester, fov: 1.2, hygMissing: true);

    expect(find.text('Chart is shallower than the sky'), findsNothing);
  });
}
