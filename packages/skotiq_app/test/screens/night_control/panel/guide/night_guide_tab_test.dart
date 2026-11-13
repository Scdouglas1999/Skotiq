// The Guide tab: the no-PHD2 state, pixels unless the guider reports its
// pixel scale, the run owning guiding, and the 300 px layout.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/night_control/actions/manual_action_gating.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/panel/guide/night_guide_tab.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

import '../scope_panel_test_support.dart';

class _Guider extends GuiderStateNotifier {
  _Guider(super.ref) {
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: kPhd2CanonicalId,
      deviceName: 'PHD2',
      isGuiding: true,
    );
  }
}

class _ScaledGuider extends GuiderStateNotifier {
  _ScaledGuider(super.ref) {
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: kPhd2CanonicalId,
      deviceName: 'PHD2',
      isGuiding: true,
      pixelScaleArcsecPerPixel: 1.5,
    );
  }
}

class _BuiltinGuider extends GuiderStateNotifier {
  _BuiltinGuider(super.ref) {
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'native:builtin_guider:multi_star',
      deviceName: 'Built-in Multi-Star Guider',
    );
  }
}

class _MockGuider extends Mock implements Phd2Controller {}

_MockGuider _guiderThatStarts() {
  final guider = _MockGuider();
  when(
    () => guider.startGuiding(
      settlePixels: any(named: 'settlePixels'),
      settleTime: any(named: 'settleTime'),
      settleTimeout: any(named: 'settleTimeout'),
    ),
  ).thenAnswer((_) async {});
  return guider;
}

class _Samples extends NightGuideSamplesNotifier {
  _Samples(super.ref) {
    final t0 = DateTime.utc(2026, 10, 19, 4);
    state = [
      for (var i = 0; i < 40; i++)
        NightGuideSample(
          t0.add(Duration(seconds: 2 * i)),
          i.isEven ? 0.3 : -0.3,
          i.isEven ? -0.4 : 0.4,
        ),
    ];
  }
}

List<Override> _connected({
  NightActionInputs? inputs,
  RecordingActionApi? api,
}) =>
    [
      ...panelOverrides(inputs: inputs, api: api),
      guiderStateProvider.overrideWith(_Guider.new),
      // Stopped, so the guide-star poll does not start in a widget test.
      phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
      nightGuideSamplesProvider.overrideWith(_Samples.new),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('with no guider it says so and offers PHD2', (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: panelOverrides(),
    );
    expectCleanLayout(tester);
    expect(find.text('PHD2'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Open PHD2'), findsOneWidget);
    expect(find.text('Connect…'), findsOneWidget);
    expect(
      find.text('Guide star'),
      findsNothing,
      reason: 'nothing pretends a guider is there',
    );
    expect(find.text('RA RMS'), findsNothing);
  });

  testWidgets('a built-in guider profile offers to connect it, never PHD2',
      (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ...panelOverrides(),
        profileGuiderProvider.overrideWithValue(
          const ProfileGuider(
            kind: ProfileGuiderKind.device,
            guiderId: 'native:builtin_guider:multi_star',
            guideCameraId: 'sim_camera_2',
          ),
        ),
      ],
    );
    expectCleanLayout(tester);
    expect(find.text('Guider'), findsWidgets);
    expect(find.text('Connect guider'), findsOneWidget);
    expect(find.text('Open PHD2'), findsNothing);
    expect(find.textContaining('PHD2'), findsNothing);
  });

  testWidgets('a profile with no guider says so and offers nothing to open',
      (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ...panelOverrides(),
        profileGuiderProvider.overrideWithValue(
          const ProfileGuider(kind: ProfileGuiderKind.none),
        ),
      ],
    );
    expectCleanLayout(tester);
    expect(
      find.text('This profile has no guider. Add one in Equipment to guide.'),
      findsOneWidget,
    );
    expect(find.textContaining('PHD2'), findsNothing);
  });

  testWidgets('guide error reads in px, never arcseconds', (tester) async {
    await pumpPanelTab(tester, const NightGuideTab(), overrides: _connected());
    expectCleanLayout(tester);
    expect(find.text('0.30 px'), findsOneWidget, reason: 'RA RMS');
    expect(find.text('0.40 px'), findsOneWidget, reason: 'Dec RMS');
    expect(find.text('0.50 px'), findsWidgets, reason: 'total and peak');
    expect(find.textContaining('″'), findsNothing);
    expect(find.textContaining('arcsec'), findsNothing);
    expect(find.text('±0.5 px'), findsOneWidget, reason: 'scatter scale');
  });

  testWidgets('guide error reads in arcseconds once the scale is reported', (
    tester,
  ) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        guiderStateProvider.overrideWith(_ScaledGuider.new),
      ],
    );
    expectCleanLayout(tester);
    expect(find.text('0.45″'), findsOneWidget, reason: 'RA RMS');
    expect(find.text('0.60″'), findsOneWidget, reason: 'Dec RMS');
    expect(find.text('0.75″'), findsWidgets, reason: 'total and peak');
    expect(find.text('±0.8″'), findsOneWidget, reason: 'scatter span');
    expect(find.text('0.30 px'), findsNothing);
  });

  testWidgets('the built-in guider never reads as PHD2', (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        guiderStateProvider.overrideWith(_BuiltinGuider.new),
      ],
    );
    expectCleanLayout(tester);
    expect(find.text('Built-in Multi-Star Guider'), findsOneWidget);
    expect(find.text('live'), findsOneWidget, reason: 'the guide star view');
    expect(find.textContaining('PHD2'), findsNothing);
  });

  // On 2026-10-25 a watcher read an autofocus guiding stop as a lost star.
  testWidgets('a planned guiding stop says what it is for', (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        guidingStopReasonProvider.overrideWith((ref) => 'autofocus'),
        guiderSettleTimeoutProvider.overrideWith(
          (ref) => (
            at: DateTime.utc(2026, 10, 25, 5, 34),
            error: 'timed-out waiting for guider to settle',
          ),
        ),
      ],
    );
    expectCleanLayout(tester);
    expect(find.text('Guiding paused for autofocus'), findsOneWidget);
    expect(find.textContaining('not a lost star'), findsOneWidget);
    expect(find.textContaining('Guide star lost'), findsNothing);
  });

  testWidgets('an unknown stop reason is shown as given', (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        guidingStopReasonProvider.overrideWith((ref) => 'new_reason'),
      ],
    );
    expect(find.text('Guiding stopped (new_reason)'), findsOneWidget);
  });

  testWidgets('no samples shows dashes, not zeros', (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ...panelOverrides(),
        guiderStateProvider.overrideWith(_Guider.new),
        phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
      ],
    );
    expect(find.text('0.00 px'), findsNothing);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a run owns guiding; Dither goes through the controller', (
    tester,
  ) async {
    final api = RecordingActionApi();
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: _connected(
        api: api,
        inputs: panelInputs(
          runState: SequenceExecutionState.running,
          isGuiding: true,
        ),
      ),
    );
    const loop = ValueKey<String>('nightGuide.loop');
    expect(isEnabled(tester, loop), isFalse);
    expect(tooltipOf(tester, loop), 'The run controls this while it is loaded');

    const dither = ValueKey<String>('nightGuide.dither');
    expect(isEnabled(tester, dither), isTrue);
    await tester.tap(find.byKey(dither));
    await tester.pump();
    expect(api.calls, ['dither']);
  });

  testWidgets('Guide starts guiding outside a run with the settle settings', (
    tester,
  ) async {
    final guider = _guiderThatStarts();
    final handle = await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        guiderStateProvider.overrideWith(_BuiltinGuider.new),
        phd2ControllerProvider.overrideWithValue(guider),
      ],
    );
    final settings = handle.container.read(appSettingsProvider.notifier);
    await tester.runAsync(() async {
      await handle.container.read(appSettingsProvider.future);
      await settings.setSettleThreshold(2.0);
      await settings.setSettleTime(15);
      await settings.setSettleTimeout(90);
    });
    await tester.pump();

    const guide = ValueKey<String>('nightGuide.guide');
    expect(find.text('Guide'), findsOneWidget);
    expect(isEnabled(tester, guide), isTrue);
    await tester.tap(find.byKey(guide));
    await tester.pump();
    verify(
      () => guider.startGuiding(
        settlePixels: 2.0,
        settleTime: 15,
        settleTimeout: 90,
      ),
    ).called(1);
  });

  testWidgets('Guide waits while a run owns the guider or it already guides', (
    tester,
  ) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(
          inputs: panelInputs(
            runState: SequenceExecutionState.running,
            isGuiding: true,
          ),
        ),
        phd2ControllerProvider.overrideWithValue(_guiderThatStarts()),
      ],
    );
    const guide = ValueKey<String>('nightGuide.guide');
    expect(isEnabled(tester, guide), isFalse);
    expect(tooltipOf(tester, guide), 'The run controls this while it is loaded');
  });

  testWidgets('Guide says why it waits while the guider already guides', (
    tester,
  ) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        // Settling after a start is guiding too; unlike guiding it starts no
        // guide-star image poll in a widget test.
        phd2StateProvider.overrideWith((ref) => Phd2State.settling),
        phd2ControllerProvider.overrideWithValue(_guiderThatStarts()),
      ],
    );
    const guide = ValueKey<String>('nightGuide.guide');
    expect(isEnabled(tester, guide), isFalse);
    expect(tooltipOf(tester, guide), 'Already guiding');
  });

  testWidgets('dither is one short word, and its cadence is the run\'s', (
    tester,
  ) async {
    await pumpPanelTab(tester, const NightGuideTab(), overrides: _connected());
    expect(find.text('Dither'), findsOneWidget);
    expect(find.text('Dither now'), findsNothing);
    // With no plan step of its own, an exposure dithers at the app setting.
    expect(find.text('3 frames'), findsOneWidget);
  });

  testWidgets('the calibration buttons are PHD2\'s and sit with its calibration',
      (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: [
        ..._connected(),
        guiderStateProvider.overrideWith(_BuiltinGuider.new),
      ],
    );
    expect(find.byKey(const ValueKey<String>('nightGuide.flipCal')), findsNothing);
    expect(find.byKey(const ValueKey<String>('nightGuide.clearCal')), findsNothing);
  });

  testWidgets('lays out at 1.3x text without overflow', (tester) async {
    await pumpPanelTab(
      tester,
      const NightGuideTab(),
      overrides: _connected(),
      textScale: 1.3,
    );
    expectCleanLayout(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pump();
    expectCleanLayout(tester);
  });
}
