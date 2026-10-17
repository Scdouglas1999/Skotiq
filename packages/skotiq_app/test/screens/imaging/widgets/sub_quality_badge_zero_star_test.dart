import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/sub_quality_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// AsyncNotifier stand-in returning fixed [ScienceSettings] synchronously so
/// the badge sees `.valueOrNull` without touching the DB.
class _FakeScienceNotifier extends ScienceSettingsNotifier {
  _FakeScienceNotifier(this._settings);

  final ScienceSettings _settings;

  @override
  Future<ScienceSettings> build() async => _settings;
}

Future<void> _pumpBadge(
  WidgetTester tester, {
  required ImageStats stats,
  required ScienceSettings science,
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
        scienceSettingsProvider.overrideWith(
          () => _FakeScienceNotifier(science),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: Center(child: SubQualityBadge())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Auto-grading on with ONLY an eccentricity threshold configured — no star
/// floor. This is the configuration under which the two graders diverged: the
/// native grader rejects a starless frame unconditionally, while the Dart
/// engine had no rule that could look at `starCount` at all, so the badge
/// printed ACCEPT over a sub that was already on disk under `Reject/`.
const _eccentricityOnly = ScienceSettings(
  autoFrameGradingEnabled: true,
  frameGradeRulesJson: '{"maxEccentricity":0.8}',
);

/// A light frame whose star detector ran and found nothing: clouds, a closed
/// dust cap, a slew that missed, or trailing past the detector's streak
/// ceiling. Every shape metric is `null` *because* there were no stars, so
/// every threshold is skipped for want of evidence, which is exactly how such a
/// frame passes a threshold-only grader.
const _starlessFrame = ImageStats(
  starCount: 0,
  hfr: null,
  fwhm: null,
  eccentricity: null,
);

void main() {
  testWidgets(
    'starless frame renders REJECT even when only an eccentricity rule is set',
    (tester) async {
      await _pumpBadge(
        tester,
        stats: _starlessFrame,
        science: _eccentricityOnly,
      );

      expect(
        find.text('REJECT'),
        findsOneWidget,
        reason:
            'the native grader files this frame under Reject/; the live badge '
            'must not tell the operator it was accepted',
      );
      expect(find.text('ACCEPT'), findsNothing);
      // The star-count chip still shows the honest measured value.
      expect(find.text('0'), findsOneWidget);
    },
  );

  testWidgets('an unmeasured star count is still not a reject', (tester) async {
    // `null` is not `0`: no detector ran, so there is no evidence either way
    // and the badge must stay on the honest-absence side of the line.
    await _pumpBadge(
      tester,
      stats: const ImageStats(starCount: null, hfr: 2.0),
      science: _eccentricityOnly,
    );

    expect(find.text('ACCEPT'), findsOneWidget);
    expect(find.text('REJECT'), findsNothing);
  });

  testWidgets('a measurable frame under the threshold still accepts', (
    tester,
  ) async {
    // The control: the zero-star rule must not turn the badge into a frame
    // shredder for ordinary good subs.
    await _pumpBadge(
      tester,
      stats: const ImageStats(starCount: 180, hfr: 2.1, eccentricity: 0.3),
      science: _eccentricityOnly,
    );

    expect(find.text('ACCEPT'), findsOneWidget);
    expect(find.text('REJECT'), findsNothing);
  });
}
