import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/quick_actions_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'camera-1',
      deviceName: 'Test Camera',
    );
  }
}

class _ConnectedFocuserNotifier extends FocuserStateNotifier {
  _ConnectedFocuserNotifier(super.ref) {
    state = const FocuserState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'focuser-1',
      deviceName: 'Test Focuser',
      position: 1000,
      isAbsolute: true,
    );
  }
}

class _ControlledImagingService extends ImagingService {
  _ControlledImagingService(super.ref);

  final result = Completer<CapturedImageData?>();
  int captureCalls = 0;

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) {
    captureCalls++;
    return result.future;
  }
}

class _ControlledDeviceService extends DeviceService {
  _ControlledDeviceService(super.ref, super.backend);

  final result = Completer<AutofocusResult>();

  @override
  Future<AutofocusResult> runAutofocus({
    double exposureTime = 3.0,
    int stepSize = 100,
    int stepsOut = 7,
    String method = 'VCurve',
    int binning = 1,
    bool useSettingsDefaults = true,
  }) =>
      result.future;
}

CapturedImageData _frame() => CapturedImageData(
      width: 2,
      height: 2,
      displayData: Uint8List(16),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 100, stdDev: 5, hfr: 1.5),
      capturedAt: DateTime.utc(2026, 7, 15),
      settings: const ExposureSettings(
        exposureTime: 1,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/old-host.fits',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('snapshot is single-flight and rejects old-host completion',
      (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    late _SwitchableBackendNotifier backendNotifier;
    late _ControlledImagingService serviceA;

    final handle = await pumpAppScreen(
      tester,
      const QuickActionsCard(colors: SkotiqColors.dark),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        imagingServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          final service = _ControlledImagingService(ref);
          if (identical(backend, backendA)) serviceA = service;
          return service;
        }),
      ],
    );

    await tester.tap(find.text('Snapshot'));
    await tester.pump();
    expect(find.text('Capturing...'), findsOneWidget);
    expect(serviceA.captureCalls, 1);

    await tester.tap(find.text('Capturing...'));
    await tester.pump();
    expect(serviceA.captureCalls, 1);
    expect(handle.container.read(sessionStateProvider).isCapturing, isTrue);

    backendNotifier.replaceBackend(backendB);
    await tester.pump();
    expect(find.text('Snapshot'), findsOneWidget);
    expect(handle.container.read(sessionStateProvider).isCapturing, isFalse);

    serviceA.result.complete(_frame());
    await tester.pump();
    expect(handle.container.read(sessionStateProvider).completedExposures, 0);
    expect(find.text('Snapshot captured'), findsNothing);
  });

  testWidgets('autofocus unlocks and hides old-host result after a switch',
      (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    late _SwitchableBackendNotifier backendNotifier;
    late _ControlledDeviceService serviceA;

    await pumpAppScreen(
      tester,
      const QuickActionsCard(colors: SkotiqColors.dark),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        focuserStateProvider.overrideWith(_ConnectedFocuserNotifier.new),
        deviceServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          final service = _ControlledDeviceService(ref, backend);
          if (identical(backend, backendA)) serviceA = service;
          return service;
        }),
      ],
    );

    await tester.tap(find.text('Autofocus'));
    await tester.pump();
    expect(find.text('Focusing...'), findsOneWidget);

    backendNotifier.replaceBackend(backendB);
    await tester.pump();
    expect(find.text('Autofocus'), findsOneWidget);

    serviceA.result.complete(
      const AutofocusResult(
        bestPosition: 1200,
        bestHfr: 1.2,
        focusData: [],
        method: 'VCurve',
        timestamp: 0,
        curveFitQuality: 1,
        backlashApplied: false,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Autofocus complete'), findsNothing);
    expect(find.text('Autofocus'), findsOneWidget);
  });
}
