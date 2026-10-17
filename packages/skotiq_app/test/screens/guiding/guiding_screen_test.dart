// Widget tests for GuidingScreen.
//
// Scope:
//
// Smoke + behavior tests:
//   1. renders_without_throwing — default harness pump under the desktop
//      width branch (1280x800) produces no uncaught exceptions and renders
//      the load-bearing status bar.
//   2. shows_disconnected_state_when_phd2_unconnected — the default
//      `phd2ConnectedProvider` (derived from `guiderStateProvider` which
//      starts disconnected) must surface the "PHD2 Disconnected" status
//      label and a "Connect" button. A regression that defaulted the
//      provider to `true` would silently render the disconnect button
//      instead, hiding the un-set-up case from new users.
//   3. shows_connect_button_in_status_bar — independent of state, the
//      [GuidingTutorialKeys.connectBtn] key must always resolve to exactly
//      one widget so the tutorial system's anchor lookup keeps working.
//      Pinning the key in a test is the only way to catch a copy/paste
//      key drift inside the production build.
//
// Why we override `tutorialProvider` to disabled: GuidingScreen wraps its
// body in `ContextualTourPrompt`, which schedules a 500 ms `Future.delayed`
// in a post-frame callback. Without disabling tutorials the test framework
// flags the still-pending timer at teardown ("A Timer is still pending even
// after the widget tree was disposed."). The same trick is used by the
// analytics-screen tests; see that file for the longer rationale.
//
// Why settle: false and fixed-step pumps: GuidingScreen renders status-dot
// glows and lostLock pulse animations that never settle. A handful of
// 50ms pumps drains the AsyncValue overrides for `starImageProvider` and
// `brainParamsProvider` without hanging.
//
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_app/widgets/tutorial_keys/guiding_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// Test-only TutorialNotifier that reports tutorials disabled so the
/// `ContextualTourPrompt` short-circuits before scheduling its 500 ms
/// `Future.delayed`. Without this override the test framework reports a
/// pending timer at teardown because the prompt is still waiting to fade in.
class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    // The disabled notifier never reads from the DAO; if any helper does,
    // surface it loudly rather than swallow it.
    throw UnimplementedError(
      'NoopTutorialProgressDao.${invocation.memberName} called in test',
    );
  }
}

class _BuiltinGuiderConnected extends GuiderStateNotifier {
  _BuiltinGuiderConnected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: builtinGuiderDeviceId,
      deviceName: 'Built-in Guider',
      isGuiding: true,
    );
  }
}

/// Drive several frames so AsyncValue providers (`starImageProvider`,
/// `brainParamsProvider`) flow through their initial loading state and the
/// PHD2 status bar lays out. We avoid `pumpAndSettle` because the connection
/// glow / lostLock pulse animations never settle.
Future<void> _drainAsyncFrames(WidgetTester tester) async {
  // 8 x 50ms = 400ms — comfortably more than the AsyncValue providers need
  // to commit their initial loading frame and shorter than the 500 ms
  // ContextualTourPrompt delay (which is disabled anyway via the override).
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<Override> _commonOverrides() {
  return [
    // Disable tutorials so the ContextualTourPrompt 500 ms delayed-show
    // timer never schedules.
    tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'renders_without_throwing: default desktop pump is exception-free',
      (tester) async {
    // 1280x800 picks the desktop Row layout (not the mobile TabBar branch),
    // which is the primary production code path. If any of the wired
    // providers (phd2ConnectedProvider, phd2StateProvider, guideStatsProvider,
    // starImageProvider, calibrationStateProvider, brainParamsProvider)
    // throws during the initial build chain under the default MockBackend,
    // this test catches it.
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _commonOverrides(),
    );
    await _drainAsyncFrames(tester);

    expect(tester.takeException(), isNull,
        reason:
            'Initial GuidingScreen pump under the default harness should not '
            'surface any uncaught exceptions.');

    // Status bar is the load-bearing chrome of the screen — its presence
    // (via tutorial key) proves the body rendered past the wrapper.
    expect(find.byKey(GuidingTutorialKeys.statusBar), findsOneWidget,
        reason: 'GuidingScreen must render the status bar.');
  });

  testWidgets(
      'shows_disconnected_state_when_phd2_unconnected: status bar advertises '
      '"PHD2 Disconnected" and the Connect button', (tester) async {
    // Default guiderState is `disconnected` → phd2ConnectedProvider returns
    // false → the status bar must show the "PHD2 Disconnected" label (only
    // visible on non-mobile widths) and the Connect button (label "Connect"
    // on non-mobile widths). A regression that defaulted phd2ConnectedProvider
    // to `true` would silently render the disconnect button instead, hiding
    // the un-set-up case from new users.
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _commonOverrides(),
    );
    await _drainAsyncFrames(tester);

    expect(find.text('PHD2 disconnected'), findsOneWidget,
        reason:
            'Default guiderState is disconnected; the desktop status bar must '
            'advertise that to the user. A connected/disconnected mismatch '
            'here would mean the phd2ConnectedProvider → status-bar binding '
            'has drifted.');
    expect(find.text('Connect'), findsOneWidget,
        reason:
            'The connect button label "Connect" must render on desktop widths '
            'when PHD2 is unconnected.');
    expect(find.text('Disconnect'), findsNothing,
        reason:
            'The "Disconnect" label is exclusive to the connected branch; if '
            'it leaks through here the status bar lost its !isConnected guard.');
  });

  testWidgets(
      'shows_connect_button_in_status_bar: GuidingTutorialKeys.connectBtn '
      'resolves to exactly one widget', (tester) async {
    // The tutorial system looks up its anchor via GuidingTutorialKeys.connectBtn;
    // a copy/paste key drift inside the production build would silently
    // break the contextual tour for the guiding screen without any compile
    // error. Pinning the key here is the cheapest way to detect that.
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _commonOverrides(),
    );
    await _drainAsyncFrames(tester);

    expect(find.byKey(GuidingTutorialKeys.connectBtn), findsOneWidget,
        reason: 'Status-bar Connect/Disconnect button must always carry the '
            'GuidingTutorialKeys.connectBtn key so the tutorial system can '
            'anchor its "Connect to PHD2" tooltip.');
    // The controls panel and graph also belong to the tutorial system; a
    // regression that nuked one would skip a tour step silently.
    expect(find.byKey(GuidingTutorialKeys.controls), findsOneWidget,
        reason: 'Right-side GuideControlsPanel must carry the controls key.');
    expect(find.byKey(GuidingTutorialKeys.graph), findsOneWidget,
        reason: 'Center-panel GuideGraphAdvanced must carry the graph key.');
  });

  testWidgets(
      'built-in guider hides PHD2-only controls and disconnects generically',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 900),
      settle: false,
      extraOverrides: [
        ..._commonOverrides(),
        guiderStateProvider.overrideWith(_BuiltinGuiderConnected.new),
        phd2StateProvider.overrideWith((ref) => Phd2State.guiding),
      ],
    );
    when(
      () => handle.backend.disconnectDevice(
        DeviceType.guider,
        builtinGuiderDeviceId,
      ),
    ).thenAnswer((_) async {});
    await _drainAsyncFrames(tester);

    expect(find.text('Built-in guider connected'), findsOneWidget);
    expect(find.text('PHD2 connected'), findsNothing);
    expect(find.text('Calibration'), findsNothing);
    expect(find.text('Brain settings'), findsNothing);
    expect(find.text('Guider settings'), findsOneWidget);

    final pause = find.descendant(
      of: find.byType(GuideControlsPanel),
      matching: find.text('Pause'),
    );
    final pauseInkWell = tester.widget<InkWell>(
      find.ancestor(of: pause, matching: find.byType(InkWell)).first,
    );
    expect(pauseInkWell.onTap, isNull);

    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    await tester.pump();

    verify(
      () => handle.backend.disconnectDevice(
        DeviceType.guider,
        builtinGuiderDeviceId,
      ),
    ).called(1);
    verifyNever(() => handle.backend.phd2Disconnect());

    // Drain DeviceReconnectCoordinator's deliberate-disconnect debounce.
    await tester.pump(const Duration(seconds: 11));
  });
}
