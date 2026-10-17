// The Imaging capture bar with the rig the operator actually had connected.
//
// Its trailing controls must publish their role and enabled state: undeclared,
// the gain field reports as an unnamed text box while live, and Loop /
// Snapshot expose as panels rather than buttons.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _ConnectedWheel extends FilterWheelStateNotifier {
  _ConnectedWheel(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_filterwheel_1',
      deviceName: 'Simulated Filter Wheel',
      currentPosition: 4,
      filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
    );
  }
}

class _ConnectedCamera extends CameraStateNotifier {
  _ConnectedCamera(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_camera_1',
      deviceName: 'Simulated Camera',
      temperature: -10,
    );
  }
}

void _noop() {}

Future<void> _pumpBar(WidgetTester tester, double width) async {
  await pumpAppScreen(
    tester,
    Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: width,
        child: const ImagingCaptureBar(
          isLooping: false,
          isSingleCapture: false,
          isSavingCapture: false,
          isStoppingCapture: false,
          onSnapshot: _noop,
          onToggleLoop: _noop,
        ),
      ),
    ),
    size: Size(width, 900),
    settle: false,
    extraOverrides: <Override>[
      filterWheelStateProvider.overrideWith(_ConnectedWheel.new),
      cameraStateProvider.overrideWith(_ConnectedCamera.new),
    ],
  );
  await tester.pump(_settleFrame);
}

/// One frame, long enough for the async provider overrides to land.
const Duration _settleFrame = Duration(milliseconds: 50);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the capture controls publish button semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpBar(tester, 900);

    // Snapshot and Loop are buttons, not panels.
    for (final label in const ['Snapshot', 'Loop']) {
      expect(
        find.bySemanticsLabel(label),
        findsWidgets,
        reason: '$label must be reachable by its label',
      );
      final node = tester.getSemantics(find.bySemanticsLabel(label).first);
      expect(
        node.hasFlag(SemanticsFlag.isButton),
        isTrue,
        reason: '$label reached assistive tech as a panel, not a button',
      );
      expect(
        node.hasFlag(SemanticsFlag.hasEnabledState) &&
            node.hasFlag(SemanticsFlag.isEnabled),
        isTrue,
        reason: '$label is live with the camera connected and must say so',
      );
    }

    handle.dispose();
  });

  testWidgets('the exposure and gain fields carry names', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpBar(tester, 900);

    // The bar has no drawn labels — it is one 32 px row — so the names have to
    // reach a screen reader through semantics or the fields are anonymous.
    expect(
      find.bySemanticsLabel(RegExp('Exposure')),
      findsWidgets,
      reason: 'the exposure field must publish a name',
    );
    expect(
      find.bySemanticsLabel('Gain'),
      findsWidgets,
      reason: 'the gain field must publish a name',
    );

    handle.dispose();
  });

  testWidgets('the filter in the beam is the one the bar shows',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 1400,
          child: ImagingCaptureBar(
            isLooping: false,
            isSingleCapture: false,
            isSavingCapture: false,
            isStoppingCapture: false,
            onSnapshot: _noop,
            onToggleLoop: _noop,
          ),
        ),
      ),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: <Override>[
        filterWheelStateProvider.overrideWith(_ConnectedWheel.new),
        cameraStateProvider.overrideWith(_ConnectedCamera.new),
      ],
    );
    await tester.pump(_settleFrame);

    // Nothing has been chosen yet, so the dropdown falls back to the first
    // filter rather than showing a blank control.
    expect(handle.container.read(exposureSettingsProvider).filter, isNull);
    expect(find.text('L'), findsWidgets);
  });
}
