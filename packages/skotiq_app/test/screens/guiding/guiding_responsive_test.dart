// Responsive widget tests for GuidingScreen (mobile responsive standard).
//
// Pumps the guiding screen at the three reference phone sizes in BOTH
// orientations and asserts:
//   * no RenderFlex / layout overflow (tester.takeException() is null),
//   * the load-bearing status bar renders,
//   * the live guide graph renders (it must stay mounted in every layout),
//   * the AdaptiveTabBar tabs are reachable (Star View / Controls / Settings).
//
// Every tab is exercised below without exempting shared UI-package overflows.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

class _SeededBrainParams extends BrainParamsNotifier {
  _SeededBrainParams(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const AsyncValue.data(
      Phd2BrainParams(
        raParamNames: ['Aggressiveness', 'Minimum move'],
        decParamNames: ['Aggressiveness', 'Minimum move'],
        raParams: {'Aggressiveness': 70, 'Minimum move': 0.15},
        decParams: {'Aggressiveness': 65, 'Minimum move': 0.20},
      ),
    );
  }
}

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _adaptiveTab(String label) {
  final semantic = find.bySemanticsLabel(label);
  return semantic.evaluate().isNotEmpty ? semantic : find.text(label);
}

/// Collects layout/overflow exceptions so the tests can report them cleanly
/// while still allowing the remaining widget tree to render for assertions.
class _OverflowGuard {
  final List<FlutterErrorDetails> allOverflows = [];
  void Function(FlutterErrorDetails)? _previous;

  void install() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      final isOverflow = text.contains('overflowed');
      if (isOverflow) {
        allOverflows.add(details);
        // Either way, don't forward overflow to the default presenter (it
        // would also trip tester.takeException()).
        return;
      }
      _previous?.call(details);
    };
  }

  void restore() {
    FlutterError.onError = _previous;
  }
}

/// The three reference phone sizes, each in portrait and the rotated landscape.
const _phoneSizes = <(String, Size)>[
  ('small phone portrait', Size(360, 640)),
  ('small phone landscape', Size(640, 360)),
  ('modern phone portrait', Size(390, 844)),
  ('modern phone landscape', Size(844, 390)),
  ('large phone portrait', Size(430, 932)),
  ('large phone landscape', Size(932, 430)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, size) in _phoneSizes) {
    testWidgets('guiding has no overflow and core elements at $name', (
      tester,
    ) async {
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
        guard.allOverflows,
        isEmpty,
        reason: 'GuidingScreen must not overflow at $name '
            '(${size.width.toInt()}x${size.height.toInt()}).',
      );
      // Any non-overflow exception is still fatal.
      expect(tester.takeException(), isNull,
          reason: 'No non-overflow exceptions at $name.');

      // Status bar (primary status) is always present.
      expect(find.byKey(GuidingTutorialKeys.statusBar), findsOneWidget,
          reason: 'Status bar must render at $name.');

      // The live guide graph stays mounted in every phone layout/orientation
      // so it keeps streaming when the user switches tabs or rotates.
      expect(find.byKey(GuidingTutorialKeys.graph), findsOneWidget,
          reason: 'Guide graph must stay mounted at $name.');

      // The Star/Controls/Settings tabs are reachable via the AdaptiveTabBar
      // (it scrolls / collapses labels to icons rather than overflowing on a
      // narrow phone). Asserting on the bar — rather than visible label text,
      // which collapses to a tooltip under 480 px — is the orientation-robust
      // check.
      expect(find.byType(AdaptiveTabBar), findsOneWidget,
          reason: 'Guiding tabs must use AdaptiveTabBar at $name.');
      // The Star View tab is selected by default; its star image carries the
      // tutorial key, proving the default tab body rendered.
      expect(find.byKey(GuidingTutorialKeys.starView), findsOneWidget,
          reason: 'Default Star View tab body must render at $name.');
    });
  }

  for (final (name, size) in const <(String, Size)>[
    ('phone portrait', Size(390, 844)),
    ('phone landscape', Size(844, 390)),
  ]) {
    testWidgets('guiding Controls and Brain tabs do not overflow on $name', (
      tester,
    ) async {
      final guard = _OverflowGuard()..install();
      addTearDown(guard.restore);

      await pumpAppScreen(
        tester,
        const GuidingScreen(),
        size: size,
        settle: false,
        extraOverrides: [
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
          brainParamsProvider.overrideWith(_SeededBrainParams.new),
        ],
      );
      await _drainAsyncFrames(tester);

      await tester.tap(_adaptiveTab('Controls'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        guard.allOverflows,
        isEmpty,
        reason: 'The Controls tab must fit at $name.',
      );

      await tester.tap(_adaptiveTab('Settings'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Show brain settings'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        guard.allOverflows,
        isEmpty,
        reason: 'The loaded Brain settings tab must fit at $name.',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
