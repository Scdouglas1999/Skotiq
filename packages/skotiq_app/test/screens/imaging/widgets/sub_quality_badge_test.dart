import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/sub_quality_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// AsyncNotifier stand-in that returns a fixed [ScienceSettings] synchronously,
/// so the badge sees `.valueOrNull` immediately without DB access.
class _FakeScienceNotifier extends ScienceSettingsNotifier {
  _FakeScienceNotifier(this._settings);

  final ScienceSettings _settings;

  @override
  Future<ScienceSettings> build() async => _settings;
}

/// Subclass that seeds a fixed [Phd2GuideStats]. The base
/// [GuideStatsNotifier] binds to `backendProvider.eventStream`; under test the
/// default [DisconnectedBackend] yields an inert empty stream, so no real
/// guide steps ever arrive to overwrite the seeded RMS.
class _FakeGuideStatsNotifier extends GuideStatsNotifier {
  _FakeGuideStatsNotifier(super.ref, Phd2GuideStats seed) {
    state = seed;
  }
}

Future<void> _pumpBadge(
  WidgetTester tester, {
  required ImageStats? stats,
  required ScienceSettings science,
  Phd2GuideStats guide = const Phd2GuideStats(),
  double? eccentricity,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        lastImageStatsProvider.overrideWith((ref) => stats),
        scienceSettingsProvider
            .overrideWith(() => _FakeScienceNotifier(science)),
        guideStatsProvider.overrideWith(
          (ref) => _FakeGuideStatsNotifier(ref, guide),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(child: SubQualityBadge(eccentricity: eccentricity)),
        ),
      ),
    ),
  );
  // Settle the async science settings + tooltip animation controllers.
  await tester.pumpAndSettle();
}

/// Science settings with auto-grading on so [resolvedFrameGradeRules] returns
/// [FrameGradeRules.conservativeDefaults] (maxHfr 3.2, minStars 25).
const _gradingOn = ScienceSettings(autoFrameGradingEnabled: true);

/// Science settings with no active rules — the verdict chip must not render.
const _gradingOff = ScienceSettings(autoFrameGradingEnabled: false);

void main() {
  testWidgets('renders nothing when there is no captured frame',
      (tester) async {
    await _pumpBadge(tester, stats: null, science: _gradingOn);

    expect(find.byType(SubQualityBadge), findsOneWidget);
    expect(find.textContaining('HFR'), findsNothing);
    expect(find.text('ACCEPT'), findsNothing);
    expect(find.text('REJECT'), findsNothing);
    // The whole subtree should collapse to a zero-size SizedBox.
    expect(tester.getSize(find.byType(SubQualityBadge)), Size.zero);
  });

  testWidgets('good HFR + stars under conservative rules shows ACCEPT',
      (tester) async {
    await _pumpBadge(
      tester,
      stats: const ImageStats(hfr: 2.10, starCount: 180),
      science: _gradingOn,
    );

    expect(find.text('ACCEPT'), findsOneWidget);
    expect(find.text('REJECT'), findsNothing);
    expect(find.text('2.10'), findsOneWidget); // HFR, tabular mono
    expect(find.text('180'), findsOneWidget); // star count
  });

  testWidgets('HFR above maxHfr shows REJECT with reason in tooltip',
      (tester) async {
    await _pumpBadge(
      tester,
      stats: const ImageStats(hfr: 4.50, starCount: 180),
      science: _gradingOn,
    );

    expect(find.text('REJECT'), findsOneWidget);
    expect(find.text('ACCEPT'), findsNothing);

    // The rejection reason must be wired into the tooltip so the user can see
    // *why* the sub was rejected on hover. Inspect the widget property rather
    // than driving the hover overlay (deterministic, no animation timing).
    final tooltip = tester.widget<SkotiqTooltip>(find.byType(SkotiqTooltip));
    expect(tooltip.message, contains('HFR 4.50 > 3.20'));
  });

  testWidgets('null eccentricity renders ECC dash', (tester) async {
    await _pumpBadge(
      tester,
      stats: const ImageStats(hfr: 2.10, starCount: 180),
      science: _gradingOff,
      eccentricity: null,
    );

    expect(find.text('ECC'), findsOneWidget);
    expect(find.text('—'), findsOneWidget); // ECC value placeholder
    // No active rules -> no verdict chip.
    expect(find.text('ACCEPT'), findsNothing);
    expect(find.text('REJECT'), findsNothing);
  });

  testWidgets('provided eccentricity renders formatted value', (tester) async {
    await _pumpBadge(
      tester,
      stats: const ImageStats(hfr: 2.10, starCount: 180),
      science: _gradingOff,
      eccentricity: 0.42,
    );

    expect(find.text('0.42'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('live guiding RMS (arcsec) above threshold drives REJECT',
      (tester) async {
    await _pumpBadge(
      tester,
      stats: const ImageStats(hfr: 2.10, starCount: 180),
      science: _gradingOn,
      // rmsTotal is arcseconds (PHD2's calibrated residual), compared against
      // conservativeDefaults.maxGuidingRmsTotalArcsec == 1.2". 2.00" > 1.20".
      guide: const Phd2GuideStats(rmsTotal: 2.0),
    );

    expect(find.text('REJECT'), findsOneWidget);

    final tooltip = tester.widget<SkotiqTooltip>(find.byType(SkotiqTooltip));
    expect(tooltip.message, contains('Guiding 2.00" > 1.20"'));
  });
}
