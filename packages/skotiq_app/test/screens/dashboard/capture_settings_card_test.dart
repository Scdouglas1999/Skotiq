import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/capture_settings_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'camera-1',
      deviceName: 'Test Camera',
    );
  }
}

/// Holds both capture entry points open so a test can inspect the card while
/// an exposure is in flight.
///
/// Capture and Loop are deliberately DIFFERENT calls on the service — Loop
/// goes through [ImagingService.startLoopCapture] so its frames land on a
/// scratch path instead of the light-frame folder — so both are stubbed and
/// counted separately here. See `capture_card_loop_retention_test.dart`.
class _ControlledImagingService extends ImagingService {
  _ControlledImagingService(super.ref);

  final captureResult = Completer<CapturedImageData?>();
  int captureCalls = 0;
  bool cancelled = false;

  /// One completer per live-view frame, held open until the test releases it.
  final _loopFrames = <Completer<void>>[];

  int get loopFrameCalls => _loopFrames.length;

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) {
    captureCalls++;
    return captureResult.future;
  }

  @override
  Future<void> startLoopCapture({
    required ExposureSettings settings,
    String? targetName,
    int? maxFrames,
    int maxConsecutiveErrors = 10,
    bool saveFrames = false,
    void Function(CapturedImageData)? onImageCaptured,
    void Function(String)? onError,
  }) async {
    final frame = Completer<void>();
    _loopFrames.add(frame);
    await frame.future;
    onImageCaptured?.call(
      CapturedImageData(
        width: 4,
        height: 4,
        displayData: Uint8List(4 * 4 * 4),
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 100, stdDev: 5),
        capturedAt: DateTime.utc(2026, 8, 2, 22),
        settings: settings,
        filePath: '/tmp/skotiq_captures/liveview_camera-1.fits',
      ),
    );
  }

  void completeLoopFrame() {
    _loopFrames.lastWhere((frame) => !frame.isCompleted).complete();
  }

  @override
  void cancelExposure() {
    cancelled = true;
  }
}

final _imagingHostProvider = StateProvider<int>((ref) => 0);

class _ConnectedFilterWheelNotifier extends FilterWheelStateNotifier {
  _ConnectedFilterWheelNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'filter-wheel-1',
      deviceName: 'Test Wheel',
      currentPosition: 0,
      filterNames: ['L', 'R'],
    );
  }
}

class _DelayedFilterDeviceService extends DeviceService {
  _DelayedFilterDeviceService(super.ref, super.backend);

  final move = Completer<void>();

  @override
  Future<void> setFilterWheelPosition(int position) => move.future;
}

Future<void> _selectFilter(
  WidgetTester tester, {
  required String current,
  required String next,
}) async {
  final dropdown = find.ancestor(
    of: find.text(current),
    matching: find.byType(DropdownButton<String>),
  );
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(next).last);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders 0-100 exposure progress as a 0-1 indicator',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
    );

    handle.container
        .read(exposureProgressProvider.notifier)
        .updateProgress(5, 5, 50);
    await tester.pump();

    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, 0.5);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('5000%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop Loop remains enabled during the in-flight exposure',
      (tester) async {
    late _ControlledImagingService imagingService;
    await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
      extraOverrides: [
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        imagingServiceProvider.overrideWith((ref) {
          return imagingService = _ControlledImagingService(ref);
        }),
      ],
    );

    await tester.tap(find.text('Loop'));
    await tester.pump();

    expect(imagingService.loopFrameCalls, 1);
    expect(imagingService.captureCalls, 0,
        reason: 'Loop is a live view; the keeper path belongs to Capture.');
    final stopButton = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Stop Loop'),
    );
    expect(stopButton.onPressed, isNotNull);

    await tester.tap(find.text('Stop Loop'));
    await tester.pump();
    expect(find.text('Loop'), findsOneWidget);
    expect(imagingService.cancelled, isFalse,
        reason: 'Stopping a loop lets the current frame finish; Abort is the '
            'separate immediate-cancel control.');

    imagingService.completeLoopFrame();
    await tester.pump();
    expect(imagingService.loopFrameCalls, 1);
  });

  testWidgets('Abort sends nothing when no exposure is in flight',
      (tester) async {
    late _ControlledImagingService imagingService;
    await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
      extraOverrides: [
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        imagingServiceProvider.overrideWith((ref) {
          return imagingService = _ControlledImagingService(ref);
        }),
      ],
    );

    await tester.tap(find.text('Loop'));
    await tester.pump();
    imagingService.completeLoopFrame();
    await tester.pump();
    // The loop is now idling between frames: Abort is still offered, but
    // there is no exposure to abort.
    expect(find.text('Stop Loop'), findsOneWidget);

    await tester.tap(find.text('Abort'));
    await tester.pump(const Duration(milliseconds: 600));

    expect(imagingService.cancelled, isFalse,
        reason: 'a cancel dispatched at idle aborts nothing and latches the '
            'service cancel flag, which blocks the NEXT loop from starting');
    expect(find.text('Loop'), findsOneWidget);
    expect(imagingService.loopFrameCalls, 1);
  });

  testWidgets('host switch stops loop and discards the old capture completion',
      (tester) async {
    late _ControlledImagingService serviceA;
    late _ControlledImagingService serviceB;
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
      extraOverrides: [
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        _imagingHostProvider.overrideWith((ref) => 0),
        imagingServiceProvider.overrideWith((ref) {
          final host = ref.watch(_imagingHostProvider);
          final service = _ControlledImagingService(ref);
          if (host == 0) {
            serviceA = service;
          } else {
            serviceB = service;
          }
          return service;
        }),
      ],
    );

    await tester.tap(find.text('Loop'));
    await tester.pump();
    expect(serviceA.loopFrameCalls, 1);
    expect(find.text('Stop Loop'), findsOneWidget);

    handle.container.read(_imagingHostProvider.notifier).state = 1;
    await tester.pump();
    expect(find.text('Loop'), findsOneWidget);

    serviceA.completeLoopFrame();
    await tester.pump();
    expect(serviceB.loopFrameCalls, 0);
    expect(find.text('Loop'), findsOneWidget);

    await tester.tap(find.text('Loop'));
    await tester.pump();
    expect(serviceB.loopFrameCalls, 1);
    serviceB.completeLoopFrame();
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('completed filter move survives card navigation', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    late _DelayedFilterDeviceService deviceService;
    final handle = await pumpAppScreen(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (context, show, _) => show
            ? const CaptureSettingsCard(colors: SkotiqColors.dark)
            : const SizedBox(),
      ),
      extraOverrides: <Override>[
        filterWheelStateProvider.overrideWith(
          _ConnectedFilterWheelNotifier.new,
        ),
        deviceServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          deviceService = _DelayedFilterDeviceService(ref, backend);
          ref.onDispose(deviceService.dispose);
          return deviceService;
        }),
      ],
    );

    await _selectFilter(tester, current: 'L', next: 'R');
    visible.value = false;
    await tester.pump();
    deviceService.move.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(handle.container.read(exposureSettingsProvider).filter, 'R');
    expect(handle.container.read(exposureSettingsUserDirtyProvider), isTrue);
  });
}
