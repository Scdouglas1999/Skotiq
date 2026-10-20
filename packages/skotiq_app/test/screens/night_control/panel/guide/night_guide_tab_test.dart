// The Guide tab: the no-PHD2 state, pixels unless the guider reports its
// pixel scale, the run owning guiding, and the 300 px layout.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/manual_action_gating.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/panel/guide/night_guide_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

List<Override> _connected(
        {NightActionInputs? inputs, RecordingActionApi? api}) =>
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
    await pumpPanelTab(tester, const NightGuideTab(),
        overrides: panelOverrides());
    expectCleanLayout(tester);
    expect(find.text('PHD2'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Open PHD2'), findsOneWidget);
    expect(find.text('Connect…'), findsOneWidget);
    expect(find.text('Guide star'), findsNothing,
        reason: 'nothing pretends a guider is there');
    expect(find.text('RA RMS'), findsNothing);
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

  testWidgets('guide error reads in arcseconds once the scale is reported',
      (tester) async {
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

  testWidgets('a run owns guiding; Dither goes through the controller',
      (tester) async {
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
