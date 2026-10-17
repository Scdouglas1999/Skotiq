import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_active_chip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Seeds a fixed [Phd2GuideStats]. The base [GuideStatsNotifier] binds to
/// `backendProvider.eventStream`; under test the default [DisconnectedBackend]
/// yields an inert empty stream, so no real guide steps overwrite the seed.
class _FakeGuideStatsNotifier extends GuideStatsNotifier {
  _FakeGuideStatsNotifier(super.ref, Phd2GuideStats seed) {
    state = seed;
  }
}

/// Guider-state notifier seeded to a fixed connection state, bypassing the
/// real [DeviceService]-driven connect path.
class _FakeGuiderStateNotifier extends GuiderStateNotifier {
  _FakeGuiderStateNotifier(super.ref, GuiderState seed) {
    state = seed;
  }
}

const _connected =
    GuiderState(connectionState: DeviceConnectionState.connected);
const _disconnected =
    GuiderState(connectionState: DeviceConnectionState.disconnected);

Future<void> _pumpChip(
  WidgetTester tester, {
  required Phd2State phd2State,
  GuiderState guider = _connected,
  Phd2GuideStats guide = const Phd2GuideStats(),
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
        phd2StateProvider.overrideWith((ref) => phd2State),
        guiderStateProvider
            .overrideWith((ref) => _FakeGuiderStateNotifier(ref, guider)),
        guideStatsProvider
            .overrideWith((ref) => _FakeGuideStatsNotifier(ref, guide)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: Center(child: GuidingActiveChip()),
        ),
      ),
    ),
  );
  // The `lost lock` StatusDot uses the `urgent` pulse, which repeats forever,
  // so `pumpAndSettle` would never return for that case. A couple of frames is
  // enough to build the tree and run the first layout pass for every state.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('renders nothing when PHD2 is stopped', (tester) async {
    await _pumpChip(tester, phd2State: Phd2State.stopped);

    expect(find.byType(GuidingActiveChip), findsOneWidget);
    expect(find.text('Guiding'), findsNothing);
    expect(find.text('Star lost'), findsNothing);
    // The whole subtree collapses to a zero-size SizedBox.
    expect(tester.getSize(find.byType(GuidingActiveChip)), Size.zero);
  });

  testWidgets(
      'renders nothing when the guider is disconnected even if PHD2 '
      'reports guiding', (tester) async {
    await _pumpChip(
      tester,
      phd2State: Phd2State.guiding,
      guider: _disconnected,
      guide: const Phd2GuideStats(rmsTotal: 0.42),
    );

    expect(find.text('Guiding'), findsNothing);
    expect(tester.getSize(find.byType(GuidingActiveChip)), Size.zero);
  });

  testWidgets('guiding + stats shows the Guiding label and arcsecond RMS',
      (tester) async {
    await _pumpChip(
      tester,
      phd2State: Phd2State.guiding,
      // rmsTotal is already arcseconds (PHD2 AvgDist / RADistanceRaw) — it is
      // labelled with the arcsec glyph, never px.
      guide: const Phd2GuideStats(rmsTotal: 0.42, snr: 18.6),
    );

    expect(find.text('Guiding'), findsOneWidget);
    expect(find.text('RMS 0.42\"'), findsOneWidget);
    // SNR rounds to nearest integer.
    expect(find.text('SNR 19'), findsOneWidget);
    // Honest: the value is arcseconds, never falsely labelled px.
    expect(find.textContaining('px'), findsNothing);
  });

  testWidgets('zero SNR is suppressed rather than shown as "SNR 0"',
      (tester) async {
    await _pumpChip(
      tester,
      phd2State: Phd2State.guiding,
      guide: const Phd2GuideStats(rmsTotal: 0.30),
    );

    expect(find.text('Guiding'), findsOneWidget);
    expect(find.textContaining('SNR'), findsNothing);
  });

  testWidgets('lost lock shows the warning Star lost label and hides RMS',
      (tester) async {
    await _pumpChip(
      tester,
      phd2State: Phd2State.lostLock,
      guide: const Phd2GuideStats(rmsTotal: 0.42, snr: 18.6),
    );

    expect(find.text('Star lost'), findsOneWidget);
    expect(find.text('Guiding'), findsNothing);
    // RMS / SNR are meaningless without a locked star.
    expect(find.textContaining('RMS'), findsNothing);
    expect(find.textContaining('SNR'), findsNothing);
  });

  testWidgets('settling shows the Settling label while locking on',
      (tester) async {
    await _pumpChip(
      tester,
      phd2State: Phd2State.settling,
      guide: const Phd2GuideStats(rmsTotal: 0.42),
    );

    expect(find.text('Settling'), findsOneWidget);
    expect(find.text('RMS 0.42\"'), findsOneWidget);
  });

  testWidgets('the dot turns warning-colored on lost lock', (tester) async {
    await _pumpChip(tester, phd2State: Phd2State.lostLock);

    const colors = SkotiqColors.dark;
    final dot = tester.widget<StatusDot>(find.byType(StatusDot));
    expect(dot.color, colors.warning);
    expect(dot.variant, StatusDotVariant.urgent);
  });

  testWidgets('the dot is a steady success-colored static dot while guiding',
      (tester) async {
    await _pumpChip(tester, phd2State: Phd2State.guiding);

    const colors = SkotiqColors.dark;
    final dot = tester.widget<StatusDot>(find.byType(StatusDot));
    expect(dot.color, colors.success);
    // Healthy guiding must NOT borrow the error/recovery `urgent` pulse — it is
    // a solid, static dot per the design system's motion language.
    expect(dot.variant, StatusDotVariant.static);
  });

  testWidgets('the dot flashes attention (one-shot) while settling',
      (tester) async {
    await _pumpChip(tester, phd2State: Phd2State.settling);

    const colors = SkotiqColors.dark;
    final dot = tester.widget<StatusDot>(find.byType(StatusDot));
    expect(dot.color, colors.success);
    expect(dot.variant, StatusDotVariant.attention);
  });

  testWidgets('tooltip explains the RMS units honestly as arcseconds',
      (tester) async {
    await _pumpChip(tester, phd2State: Phd2State.guiding);

    final tooltip = tester.widget<SkotiqTooltip>(find.byType(SkotiqTooltip));
    expect(tooltip.message, contains('PHD2 guiding active'));
    expect(tooltip.message, contains('arcseconds'));
  });
}
