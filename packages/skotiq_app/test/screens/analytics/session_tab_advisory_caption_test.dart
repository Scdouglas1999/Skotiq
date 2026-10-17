// The Captured Images caption on Analytics > Session claimed "No frames are
// deleted or auto-rejected" while the frame grader two tabs away (Science >
// Field Quality > Grade N frames) sets is_accepted = 0 and stamps
// rejection_reason 'Auto-grade: ...'. The caption is now scoped to the badges
// and names the thing that does reject.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'NoopTutorialProgressDao.${invocation.memberName} called in test',
      );
}

DbCapturedImage _standaloneFrame() => DbCapturedImage(
      id: 1,
      filePath: '/tmp/1.fits',
      fileName: '1.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 30,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 1, 22),
      createdAt: DateTime.utc(2026, 8, 1, 22),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the captured-images caption does not deny the frame grader',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 1200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value(const []),
          ),
          // One standalone frame, so the tab renders the quick-capture card
          // this test is about rather than the "nothing captured yet" empty
          // state it now shows when there is genuinely nothing.
          standaloneImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value([_standaloneFrame()]),
          ),
          allDbImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.session),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final captions = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where((s) => s.contains('Quality badges are advisory'))
        .toList();
    expect(captions, hasLength(1),
        reason: 'the Captured Images caption should render exactly once');
    final caption = captions.single;
    expect(caption, contains('Grade frames'),
        reason: 'the caption must point at the thing that does reject frames');
    // The destination has to be one the navigation actually has. "Science >
    // Grade frames" is not a place — the bulk grader is the "Grade N frames"
    // button on Analytics ▸ Science ▸ Field Quality.
    expect(caption, isNot(contains('Science > Grade frames')));
    // Sentence case (06 copy rules) on both the jump-nav chip and the
    // caption that points at it: they still have to be the same words.
    expect(caption, contains('Field quality'));
    expect(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => s.contains('auto-rejected')),
      isEmpty,
      reason: 'nothing may claim frames are never auto-rejected',
    );
  });
}
