// Regression test: expanding "Brain Settings" with PHD2 disconnected must say
// so, not shimmer forever.
//
// Observed on the running desktop build with PHD2 not running: pressing "Brain
// Settings" flipped the label to "Hide Brain Settings" and expanded into six
// grey skeleton rows that were still shimmering minutes later — no values, no
// message, no error.
//
// The cause is exact. BrainParamsNotifier
// (skotiq_core/.../guiding_provider/brain_and_calibration.dart) is
// constructed in AsyncValue.loading() and only ever calls fetch() when the
// guider is connected AND deviceId == kPhd2CanonicalId; its disconnect
// listener resets it to loading again. So with PHD2 absent the provider can
// never leave `loading`, and the panel's `loading:` branch was an
// unconditional shimmer. The panel's real error branch (with its Retry button)
// is not missing — it is simply unreachable, because nothing ever throws.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
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

/// PHD2 connected, which is the only state in which a brain-params fetch can
/// actually be in flight.
class _Phd2Connected extends GuiderStateNotifier {
  _Phd2Connected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: kPhd2CanonicalId,
      deviceName: 'PHD2',
    );
  }
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'brain_settings_disconnected_explains_itself: with PHD2 down the panel '
      'says why instead of shimmering forever', (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 900),
      settle: false,
      extraOverrides: [
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
      ],
    );
    await _drain(tester);

    // Default guiderState is disconnected — the reported starting condition.
    expect(find.text('Brain settings'), findsOneWidget);
    await tester.tap(find.text('Brain settings'));
    await _drain(tester);

    expect(find.text('Hide brain settings'), findsOneWidget,
        reason: 'The section must still expand — the defect was the content, '
            'not the toggle.');

    // Even after generously more time than a real fetch would take, the
    // provider cannot leave `loading`, so a shimmer here is a permanent lie.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      find.byType(ShimmerLoading),
      findsNothing,
      reason: 'No brain-params request can ever be issued while PHD2 is '
          'disconnected, so a loading skeleton claims work that is not '
          'happening.',
    );
    expect(find.text('Brain settings need PHD2'), findsOneWidget,
        reason: 'The panel must name the reason there is nothing to show.');
    expect(
      find.text(
          "These are PHD2's own guiding parameters. Connect PHD2 to read and "
          'edit them.'),
      findsOneWidget,
      reason: 'And it must say what would make them available.',
    );
  });

  testWidgets(
      'brain_settings_connected_keeps_the_real_loading_and_error_paths: the '
      'fix must not swallow a genuine fetch', (tester) async {
    final backend = mockBackend();
    // A request that never answers: the honest rendering of that IS the
    // skeleton, so it must survive where it is correct.
    when(() => backend.phd2GetAlgoParamNames(axis: any(named: 'axis')))
        .thenAnswer((_) => Completer<List<String>>().future);

    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 900),
      settle: false,
      backend: backend,
      extraOverrides: [
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        guiderStateProvider.overrideWith(_Phd2Connected.new),
      ],
    );
    await _drain(tester);

    await tester.tap(find.text('Brain settings'));
    await _drain(tester);

    expect(find.byType(ShimmerLoading), findsWidgets,
        reason: 'With PHD2 connected and a request in flight the skeleton is '
            'the honest rendering and must survive the fix.');
    expect(find.text('Brain settings need PHD2'), findsNothing,
        reason: 'PHD2 IS connected here — claiming otherwise would just move '
            'the false statement.');
  });

  testWidgets(
      'brain_settings_connected_still_surfaces_a_failed_fetch: the error '
      'branch stays reachable', (tester) async {
    final backend = mockBackend();
    when(() => backend.phd2GetAlgoParamNames(axis: any(named: 'axis')))
        .thenThrow(StateError('PHD2 refused the request'));

    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 900),
      settle: false,
      backend: backend,
      extraOverrides: [
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        guiderStateProvider.overrideWith(_Phd2Connected.new),
      ],
    );
    await _drain(tester);

    await tester.tap(find.text('Brain settings'));
    await _drain(tester);

    expect(find.text('Brain settings did not load'), findsOneWidget,
        reason: 'A real failure must still reach the error branch with its '
            'Retry button.');
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Brain settings need PHD2'), findsNothing);
  });
}
