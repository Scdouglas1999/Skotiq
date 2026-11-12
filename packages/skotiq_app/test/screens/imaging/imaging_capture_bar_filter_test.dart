// The capture bar's filter dropdown names the filter the next frame is taken
// through, and choosing one moves the wheel there before the exposure.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// A wheel sitting on R (slot 1), as the simulator comes up after a relaunch.
class _WheelOnR extends FilterWheelStateNotifier {
  _WheelOnR(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_filterwheel_1',
      deviceName: 'Simulated Filter Wheel',
      currentPosition: 1,
      filterNames: ['L', 'R', 'G', 'B', 'Ha'],
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
    );
  }
}

class _RecordingDeviceService extends DeviceService {
  _RecordingDeviceService(super.ref, super.backend);

  final List<int> moves = <int>[];

  @override
  Future<void> setFilterWheelPosition(int position) async {
    moves.add(position);
  }
}

void _noop() {}

const Duration _settleFrame = Duration(milliseconds: 50);

Future<(HarnessHandle, _RecordingDeviceService)> _pumpBar(
    WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: 1100,
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
    size: const Size(1100, 900),
    settle: false,
    extraOverrides: <Override>[
      filterWheelStateProvider.overrideWith(_WheelOnR.new),
      cameraStateProvider.overrideWith(_ConnectedCamera.new),
      deviceServiceProvider.overrideWith((ref) {
        final backend = ref.watch(backendProvider);
        final service = _RecordingDeviceService(ref, backend);
        ref.onDispose(service.dispose);
        return service;
      }),
    ],
  );
  await tester.pump(_settleFrame);
  return (
    handle,
    handle.container.read(deviceServiceProvider) as _RecordingDeviceService,
  );
}

String? _shownFilter(WidgetTester tester) {
  final dropdown = tester.widget<SkotiqDropdown>(
    find.byWidgetPredicate(
        (w) => w is SkotiqDropdown && w.items.contains('Ha')),
  );
  return dropdown.value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the dropdown shows the filter loaded in the wheel',
      (tester) async {
    await _pumpBar(tester);
    expect(_shownFilter(tester), 'R');
  });

  testWidgets('choosing a filter moves the wheel and records it',
      (tester) async {
    final (handle, deviceService) = await _pumpBar(tester);

    final dropdown = tester.widget<SkotiqDropdown>(
      find.byWidgetPredicate(
          (w) => w is SkotiqDropdown && w.items.contains('Ha')),
    );
    dropdown.onChanged!('G');
    await tester.pump();
    await tester.pump(_settleFrame);

    expect(deviceService.moves, <int>[2]);
    expect(handle.container.read(exposureSettingsProvider).filter, 'G');
  });
}
