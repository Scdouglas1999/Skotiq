// An off grading rule has to look the same wherever it appears.
//
// Observed: in the Image grader "Max FWHM" read "off" with its thumb pinned at
// the far LEFT of the track while the very next row, "Max eccentricity", also
// read "off" with its thumb pinned at the far RIGHT. Two adjacent disabled
// rules, the same word, opposite pictures — each reading as a threshold that
// was in force. The cause was a degenerate range: when every frame carries the
// same value the track runs `min .. min + 1` but the off value was clamped to
// `rangeMax == rangeMin`, i.e. the bottom of the track.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_grader_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _NoRules extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => ScienceSettings(
        frameGradeRulesJson: const FrameGradeRules().toJsonString(),
      );
}

/// A persisted rule set whose "Min stars" threshold sits one above the only
/// star count in the session, i.e. at the top of the widened degenerate track.
class _MinStarsAtTop extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => ScienceSettings(
        frameGradeRulesJson:
            const FrameGradeRules(minStars: 701).toJsonString(),
      );
}

DbCapturedImage _frame(int id) => DbCapturedImage(
      id: id,
      filePath: '/data/m13_$id.fits',
      fileName: 'm13_$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 1, 5, id),
      createdAt: DateTime.utc(2026, 8, 1, 5, id),
      isAccepted: true,
      isPlateSolved: false,
      // Every frame shares one HFR, which is what produced the degenerate
      // range that parked an off rule at the wrong end.
      hfr: 2.4,
      starCount: 700,
      guidingRmsTotal: 0.5,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('threshold track', () {
    test('an off Max rule sits at the top even on a degenerate range', () {
      // Every frame shares one HFR: rangeMin == rangeMax, so the track is
      // widened and the off thumb has to follow it to the top.
      expect(thresholdSliderMax(2.4, 2.4), 3.4);
      expect(
        maxRuleThumbValue(null, 2.4, 2.4),
        3.4,
        reason: 'clamping the off value to rangeMax parked it at the BOTTOM '
            'of a track that runs to rangeMin + 1',
      );
    });

    test('a normal range is unchanged, and a set value is respected', () {
      expect(thresholdSliderMax(0.0, 12.0), 12.0);
      expect(maxRuleThumbValue(null, 0.0, 12.0), 12.0);
      expect(maxRuleThumbValue(3.5, 0.0, 12.0), 3.5);
      expect(maxRuleThumbValue(99.0, 0.0, 12.0), 12.0);
    });

    // The "Min stars" row runs the same widened track and had the same clamp
    // bug in the opposite direction: its thumb was clamped to rangeMax while
    // the track ran to rangeMin + 1, so a value dragged to the top of a
    // degenerate track sprang back to the bottom with the readout left
    // showing the higher number.
    test('a Min rule parks at the bottom but can still reach the top', () {
      expect(minRuleThumbValue(null, 700, 700), 700,
          reason: 'off "Min stars" accepts any star count — permissive end');
      expect(
        minRuleThumbValue(701, 700, 700),
        701,
        reason: 'the track runs 700..701 on a degenerate range, so a set '
            'value of 701 must sit at the top, not clamp back to 700',
      );
      expect(minRuleThumbValue(null, 0, 200), 0);
      expect(minRuleThumbValue(120, 0, 200), 120);
      expect(minRuleThumbValue(999, 0, 200), 200);
    });
  });

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1200, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('every off rule parks its thumb at the permissive end',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceSettingsProvider.overrideWith(_NoRules.new)
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => ImageGraderDialog.show(
                  context,
                  frames: [_frame(0), _frame(1)],
                ),
                child: const Text('Open grader'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open grader'));
    await tester.pumpAndSettle();

    // HFR / stars / guiding are suggested from the frames; FWHM and
    // eccentricity have no PSF products here, so those two rows are off.
    expect(find.text('off'), findsNWidgets(2));

    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, hasLength(5));

    // Rows 1 and 2 are Max FWHM and Max eccentricity — both off, both at the
    // permissive (top) end of their own track.
    for (final slider in [sliders[1], sliders[2]]) {
      expect(
        slider.value,
        slider.max,
        reason: 'an off "Max" rule must sit at the permissive (top) end',
      );
    }
  });

  testWidgets('a set Min stars rule keeps its thumb where its readout says',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceSettingsProvider.overrideWith(_MinStarsAtTop.new)
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => ImageGraderDialog.show(
                  context,
                  // ONE frame, so every range is degenerate — the common case
                  // when grading a single sub.
                  frames: [_frame(0)],
                ),
                child: const Text('Open grader'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open grader'));
    await tester.pumpAndSettle();

    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, hasLength(5));
    final minStars = sliders[3];

    expect(minStars.max, 701, reason: 'degenerate range widens the track');
    expect(find.text('701'), findsOneWidget);
    expect(
      minStars.value,
      701,
      reason: 'the readout says 701, so the thumb must be at 701 — clamping '
          'it to rangeMax sprang it back to the bottom of the track',
    );
  });

  testWidgets('an off rule is dimmed so it does not read as a threshold',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceSettingsProvider.overrideWith(_NoRules.new)
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => ImageGraderDialog.show(
                  context,
                  frames: [_frame(0), _frame(1)],
                ),
                child: const Text('Open grader'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open grader'));
    await tester.pumpAndSettle();

    // The two off rows are dimmed; the three suggested ones are not.
    final opacities = tester
        .widgetList<Opacity>(
          find.ancestor(
            of: find.byType(Slider),
            matching: find.byType(Opacity),
          ),
        )
        .map((o) => o.opacity)
        .toList();
    expect(opacities, hasLength(5));
    expect(
      opacities.where((o) => o < 1.0).length,
      2,
      reason: 'an off rule must not look like a threshold that is in force',
    );
  });
}
