// Regression tests for the guiding screen at a short viewport.
//
// A persistent banner above the shell (the "Notifications are disabled" strip
// is the one that shipped) shrinks the guiding body's available height. The
// phone layout used to floor the graph at a fixed 200 dp while capping it at
// 60% of the available height, so below ~333 dp the clamp bounds inverted,
// `double.clamp` threw, and the release build replaced the whole screen with a
// blank grey ErrorWidget.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/widgets/tutorial_keys/guiding_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'NoopTutorialProgressDao.${invocation.memberName} called in test',
    );
  }
}

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _OverflowGuard {
  final List<FlutterErrorDetails> allOverflows = [];
  void Function(FlutterErrorDetails)? _previous;

  void install() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) {
        allOverflows.add(details);
        return;
      }
      _previous?.call(details);
    };
  }

  void restore() {
    FlutterError.onError = _previous;
  }
}

/// Heights that put the guiding body below the 333 dp inversion point, plus one
/// just above it so the normal path stays covered.
const _shortHeights = <(String, Size)>[
  ('banner-squeezed phone', Size(411, 300)),
  ('banner-squeezed small phone', Size(360, 300)),
  ('very short phone', Size(411, 260)),
  ('just above the old inversion point', Size(411, 340)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, size) in _shortHeights) {
    testWidgets('guiding renders at $name', (tester) async {
      final guard = _OverflowGuard()..install();
      addTearDown(guard.restore);

      await pumpAppScreen(
        tester,
        const GuidingScreen(),
        size: size,
        settle: false,
        extraOverrides: [
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        ],
      );
      await _drainAsyncFrames(tester);

      expect(
        tester.takeException(),
        isNull,
        reason: 'The guiding layout must not throw at $name '
            '(${size.width.toInt()}x${size.height.toInt()}).',
      );
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'A thrown build must not replace the guiding screen with the '
            'blank grey ErrorWidget at $name.',
      );
      expect(
        guard.allOverflows,
        isEmpty,
        reason: 'The guiding layout must not overflow at $name.',
      );

      expect(
        find.byKey(GuidingTutorialKeys.graph),
        findsOneWidget,
        reason: 'The guide graph must stay mounted at $name.',
      );
      expect(
        find.byType(AdaptiveTabBar),
        findsOneWidget,
        reason: 'The Star/Controls/Settings tabs must stay reachable at $name.',
      );

      // Not merely "did not throw": both regions keep a usable share. Since
      // the Observatory overhaul the tab strip lives in the PageHeader (04
      // §4), so it sits ABOVE the graph rather than below it; what is pinned
      // here is that neither is squeezed to nothing and they do not overlap.
      final graphBox = tester.getRect(find.byKey(GuidingTutorialKeys.graph));
      final tabsBox = tester.getRect(find.byType(AdaptiveTabBar));
      expect(
        graphBox.height,
        greaterThan(40),
        reason: 'The plot must keep a legible slice of a short viewport at '
            '$name (got ${graphBox.height}).',
      );
      expect(
        graphBox.top,
        greaterThanOrEqualTo(tabsBox.bottom),
        reason: 'The graph must sit below the header tab strip, not overlap '
            'it, at $name.',
      );
    });
  }
}
