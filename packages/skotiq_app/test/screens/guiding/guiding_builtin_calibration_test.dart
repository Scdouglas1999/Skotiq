// The Guiding screen with the built-in guider: its calibration is shown like
// PHD2's (without PHD2's Clear and Flip), and a control it cannot use looks
// unavailable. The screen used to show only "Skotiq calibrates this guider
// itself" and an outline Pause that looked as live as Loop.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const Size _desktop = Size(1646, 960);

class _TutorialsDisabled extends TutorialNotifier {
  _TutorialsDisabled() : super(_NoopDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _BuiltinConnected extends GuiderStateNotifier {
  _BuiltinConnected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: builtinGuiderDeviceId,
      deviceName: 'Built-in Multi-Star Guider',
    );
  }
}

class _Calibrated extends CalibrationStateNotifier {
  _Calibrated(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2CalibrationData(
      isCalibrated: true,
      raRate: 16.0,
      decRate: 12.0,
      rotationAngle: 10.2,
    );
  }
}

void main() {
  testWidgets('the built-in guider shows its calibration, without PHD2 tools',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: _desktop,
      settle: false,
      extraOverrides: [
        tutorialProvider.overrideWith((ref) => _TutorialsDisabled()),
        guiderStateProvider.overrideWith(_BuiltinConnected.new),
        // Stopped, so the guide-star image poll does not start in a test.
        phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
        calibrationStateProvider.overrideWith(_Calibrated.new),
      ],
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);

    expect(find.text('Calibration'), findsOneWidget);
    expect(find.text('Calibrated'), findsOneWidget);
    expect(find.text('RA RATE'), findsOneWidget);
    expect(
      find.textContaining('16.00', findRichText: true),
      findsOneWidget,
      reason: 'RA rate',
    );
    expect(
      find.textContaining('12.00', findRichText: true),
      findsOneWidget,
      reason: 'Dec rate',
    );
    expect(find.text('Clear'), findsNothing, reason: 'PHD2 only');
    expect(find.text('Flip'), findsNothing, reason: 'PHD2 only');

    // Pause is PHD2's: here it is shown, unavailable, at the design system's
    // disabled opacity.
    final pause = find.ancestor(
      of: find.text('Pause'),
      matching: find.byType(AnimatedOpacity),
    );
    expect(
      tester.widget<AnimatedOpacity>(pause.first).opacity,
      SkotiqTokens.opacityDisabled,
    );
  });
}
