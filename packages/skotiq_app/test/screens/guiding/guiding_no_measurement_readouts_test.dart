// Regression tests: the Guiding screen must not state guiding quality it has
// not measured.
//
// Observed on the running release build with the built-in guider connected and
// state "Guiding" but no guide step measured yet (also the state it returns to
// after Stop, because `GuidingStopped` resets the stats):
//
//   * the Guide Graph header read "RA: 0.00 px  Dec: 0.00 px  Total: 0.00 px"
//     and the row beneath it "RA: 0.00\"  Dec: 0.00\"  Tot: 0.00\"" — a
//     fabricated perfect-guiding claim, in two contradictory units, while the
//     Equipment and Dashboard guider cards correctly showed dashes;
//   * "Star Statistics" showed SNR 0.0 painted error-red with Star Mass 0;
//   * the Guide Star preview said "Waiting for image..." although nothing had
//     been requested (the star-image notifier only polls while looping /
//     guiding / calibrating and otherwise sits in AsyncValue.loading forever).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

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

class _GuiderConnected extends GuiderStateNotifier {
  _GuiderConnected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: builtinGuiderDeviceId,
      deviceName: 'Built-in Guider',
      isGuiding: true,
    );
  }
}

/// Guide stats carrying real samples (values are guide-camera pixels, and no
/// pixel scale is known — the built-in guider reports none).
class _MeasuredStats extends GuideStatsNotifier {
  _MeasuredStats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.53,
      rmsDec: 0.57,
      rmsTotal: 0.78,
      snr: 24.5,
      starMass: 18342,
      frameCount: 37,
    );
  }
}

/// While PHD2 loops or guides the guide-star image is polled on a timer, for
/// as long as something shows it. Close the screen and its provider scope
/// before the test ends so the poll stops with them, as it does when the app
/// closes. (Tearing down the whole tree also removes the scope that would run
/// the poll's auto-dispose, so the container is disposed here directly.)
Future<void> _closeScreen(WidgetTester tester, HarnessHandle handle) async {
  await tester.pumpWidget(const SizedBox());
  handle.container.dispose();
}

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<Override> _overrides({bool measured = false}) => [
      tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
      guiderStateProvider.overrideWith(_GuiderConnected.new),
      phd2StateProvider.overrideWith((ref) => Phd2State.guiding),
      if (measured) guideStatsProvider.overrideWith(_MeasuredStats.new),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no guide step measured yet renders dashes, never 0.00',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: _overrides(),
    );
    await _drainAsyncFrames(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('0.00'),
      findsNothing,
      reason: 'a fabricated 0.00 RMS reads as flawless guiding',
    );
    // The graph's own stats row (RA / Dec / Tot) plus the SNR and Star mass
    // readouts. The duplicate RMS chips that used to sit in the screen's own
    // status bar are gone (06 §Guiding: one status surface), so five, not
    // eight.
    expect(find.text('—'), findsAtLeastNWidgets(5));
    await _closeScreen(tester, handle);
  });

  testWidgets('star statistics show dashes rather than a red 0.0 SNR',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: _overrides(),
    );
    await _drainAsyncFrames(tester);

    expect(find.text('SNR'), findsOneWidget);
    expect(
      find.text('0.0'),
      findsNothing,
      reason: 'an unmeasured SNR was painted error-red as 0.0',
    );
    expect(find.text('MASS'), findsOneWidget);
    // SNR + Star mass join the graph's three RMS readouts.
    expect(find.text('—'), findsAtLeastNWidgets(5));
    // Frame count of zero is a real count, so it still renders as a number.
    expect(find.text('FRAMES'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    await _closeScreen(tester, handle);
  });

  testWidgets('measured samples render once, in one consistent unit',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: _overrides(measured: true),
    );
    await _drainAsyncFrames(tester);

    // Graph header + graph stats row both label the same number px, because no
    // pixel scale is known — one must not print 0.53 px and the other 0.53"
    // fifty pixels below it.
    expect(find.text('0.53 px'), findsAtLeastNWidgets(1));
    expect(
      find.text('0.53"'),
      findsNothing,
      reason: 'pixels must never be labelled arcseconds',
    );
    expect(find.text('24.5'), findsOneWidget, reason: 'real SNR shows through');
    await _closeScreen(tester, handle);
  });

  testWidgets('idle guider is not told it is waiting for an image',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: [
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        guiderStateProvider.overrideWith(_GuiderConnected.new),
        phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.text('Waiting for image...'), findsNothing);
    expect(
      find.text('Press Loop Exposures or Start to acquire a guide star'),
      findsOneWidget,
    );
  });
}
