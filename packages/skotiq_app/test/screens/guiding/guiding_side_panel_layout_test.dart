// The Guiding side panel at the owner's 1920x1080 desktop.
//
// The controls, calibration and Brain toggle were three flex slots: the
// controls scrolled inside theirs, and calibration's slot ran on empty below
// its readouts down to a Brain button pinned at the bottom of the panel. They
// are one column now, each at its own height.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_app/widgets/tutorial_keys/guiding_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// The screen's share of a 1920x1080 window: the navigation rail and the top
/// bar take the rest.
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

class _Calibrated extends CalibrationStateNotifier {
  _Calibrated(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2CalibrationData(
      isCalibrated: true,
      raRate: 2.21,
      decRate: 5.56,
      rotationAngle: -130.8,
    );
  }
}

void main() {
  testWidgets('controls, calibration and Brain settings stack without a gap',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: _desktop,
      settle: false,
      extraOverrides: [
        tutorialProvider.overrideWith((ref) => _TutorialsDisabled()),
        guiderStateProvider.overrideWith(_Phd2Connected.new),
        phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
        calibrationStateProvider.overrideWith(_Calibrated.new),
      ],
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);

    final controls = find.byKey(GuidingTutorialKeys.controls);
    expect(
      find.descendant(of: controls, matching: find.byType(Scrollable)),
      findsNothing,
      reason: 'the controls do not scroll inside the side panel',
    );
    // Everything the controls hold is laid out on screen, Dither and Settle
    // included.
    for (final label in ['Dither now', 'Settle settings']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.bottom, lessThanOrEqualTo(_desktop.height), reason: label);
    }

    final controlsRect = tester.getRect(find.byType(GuideControlsPanel));
    final calibration = tester.getRect(find.text('Calibration'));
    expect(
      calibration.top - controlsRect.bottom,
      lessThanOrEqualTo(SidePanel.sectionGap + SkotiqTokens.spaceLg),
      reason: 'calibration follows the controls',
    );

    final flipNote = tester
        .getRect(find.text('Flip the calibration after a meridian flip.'));
    final brain = tester.getRect(find.byKey(GuidingTutorialKeys.brainBtn));
    expect(
      brain.top - flipNote.bottom,
      lessThanOrEqualTo(SidePanel.sectionGap),
      reason: 'Brain settings follows calibration instead of sitting at the '
          'bottom of the panel',
    );
  });
}
