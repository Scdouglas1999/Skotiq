// The image grader's list of frames it is about to reject opened below the
// fold: only the first row was visible and it was cut in half by the
// Cancel / "Reject N frames" bar, with no scroll affordance. The list is the
// confirmation for a destructive-looking action, so it is now pinned above the
// footer in its own bounded, scrollable box.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_grader_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _RejectEverythingSettings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => ScienceSettings(
        frameGradeRulesJson:
            const FrameGradeRules(maxGuidingRmsTotalArcsec: 0.24)
                .toJsonString(),
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
      guidingRmsTotal: 0.60,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('the frames about to be rejected are visible above the footer',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          scienceSettingsProvider.overrideWith(_RejectEverythingSettings.new),
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

    expect(find.textContaining('Will reject'), findsOneWidget);

    // Both rows and both reasons are on screen without scrolling anything.
    final footerTop = tester.getRect(find.text('Cancel')).top;
    for (final name in ['m13_0.fits', 'm13_1.fits']) {
      final row = find.text(name);
      expect(row, findsOneWidget, reason: '$name is not in the tree');
      final rect = tester.getRect(row);
      expect(rect.bottom, lessThanOrEqualTo(footerTop),
          reason: '$name is clipped by the action bar');
      expect(rect.top, greaterThanOrEqualTo(0.0));
    }
    expect(find.textContaining('Guiding 0.60" > 0.24"'), findsNWidgets(2));

    // And the list carries its own scrollbar, so a longer list announces that
    // there is more below.
    expect(
      find.descendant(
        of: find.byType(ImageGraderDialog),
        matching: find.byType(Scrollbar),
      ),
      findsWidgets,
    );
  });
}
