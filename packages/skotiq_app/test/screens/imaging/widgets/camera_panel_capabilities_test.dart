// Widget tests for CameraPanel capability-driven controls (component C9).
//
// Scope:
//   1. cooler_slider_uses_capability_range — when CameraCapabilities reports
//      coolerMinTempC/coolerMaxTempC, the target-temperature slider adopts
//      that range instead of the -30..20 default.
//   2. cooler_slider_falls_back_with_null_caps — when capabilities are null,
//      the slider uses the conservative -30..20 default window.
//   3. read_mode_lists_capability_modes — when readoutModes is non-empty the
//      Read Mode dropdown lists exactly those modes (no synthetic
//      High Quality/Fast fallback).
//   4. read_mode_hidden_when_no_modes — when readoutModes is empty the entire
//      Read Mode row is hidden (hide-when-unsupported pattern).
//
// Why we read the live SliderRowInteractive min/max rather than dragging the
// slider: the load-bearing behavior of C9 is the *range wiring*, and asserting
// on the widget's resolved min/max is a direct, non-flaky check of exactly that.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/camera_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

const _kDeviceId = 'simulator:camera:0';

/// A [CameraStateNotifier] seeded to a connected device so the panel renders
/// its interactive (non-disabled) controls and resolves capabilities for the
/// matching device id.
class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: _kDeviceId,
      deviceName: 'Simulated Camera',
      temperature: -5.0,
    );
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

/// Locate the target-temperature [SliderRowInteractive] (the only slider the
/// panel renders) and return it for min/max assertions.
SliderRowInteractive _coolerSlider(WidgetTester tester) {
  return tester.widget<SliderRowInteractive>(
    find.byType(SliderRowInteractive),
  );
}

/// Build the standard override list pinning the camera to connected and the
/// capability provider for [_kDeviceId] to [caps].
List<Override> _overrides(CameraCapabilities? caps) => [
      cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
      cameraCapabilitiesProvider(_kDeviceId).overrideWith((ref) async => caps),
    ];

CameraCapabilities _caps({
  double? coolerMin,
  double? coolerMax,
  List<String> readoutModes = const [],
}) {
  return CameraCapabilities(
    maxWidth: 1920,
    maxHeight: 1080,
    bitDepth: 16,
    canSetCcdTemperature: true,
    canSetCooler: true,
    canGetCoolerPower: true,
    coolerMinTempC: coolerMin,
    coolerMaxTempC: coolerMax,
    readoutModes: readoutModes,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester,
  CameraCapabilities? caps,
) async {
  await pumpAppScreen(
    tester,
    const CameraPanel(colors: SkotiqColors.dark),
    extraOverrides: _overrides(caps),
    settle: false,
  );
  // Drain the capability FutureProvider override into the tree.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'cooler_slider_uses_capability_range: slider adopts coolerMin/Max from caps',
      (tester) async {
    await _pumpPanel(
      tester,
      _caps(coolerMin: -20, coolerMax: 40, readoutModes: const ['A', 'B']),
    );

    final slider = _coolerSlider(tester);
    expect(slider.min, -20,
        reason: 'Slider min must come from CameraCapabilities.coolerMinTempC.');
    expect(slider.max, 40,
        reason: 'Slider max must come from CameraCapabilities.coolerMaxTempC.');
  });

  testWidgets(
      'cooler_slider_falls_back_with_null_caps: slider is -30..20 when caps null',
      (tester) async {
    await _pumpPanel(tester, null);

    final slider = _coolerSlider(tester);
    expect(slider.min, -30,
        reason: 'Null capabilities must fall back to the -30°C default min.');
    expect(slider.max, 20,
        reason: 'Null capabilities must fall back to the 20°C default max.');
  });

  testWidgets(
      'cooler_slider_falls_back_on_inverted_range: guards against bad driver data',
      (tester) async {
    // min >= max is nonsensical driver data; the panel must ignore it and use
    // the conservative default window rather than feeding the Slider an
    // invalid range (which would assert).
    await _pumpPanel(tester, _caps(coolerMin: 50, coolerMax: 10));

    final slider = _coolerSlider(tester);
    expect(slider.min, -30);
    expect(slider.max, 20);
  });

  testWidgets(
      'read_mode_lists_capability_modes: dropdown lists exactly the cap modes',
      (tester) async {
    await _pumpPanel(
      tester,
      _caps(readoutModes: const ['Mode A', 'Mode B']),
    );

    // The Read Mode row renders a DropdownRow whose items are the cap modes.
    final readModeRow = tester.widgetList<DropdownRow>(
      find.byType(DropdownRow),
    );
    final dropdowns = readModeRow.where((d) => d.label == 'Read mode').toList();
    expect(dropdowns, hasLength(1),
        reason: 'Read Mode row must be present when modes are reported.');
    expect(dropdowns.single.items, ['Mode A', 'Mode B'],
        reason:
            'Dropdown items must mirror CameraCapabilities.readoutModes with no '
            'synthetic High Quality/Fast fallback.');
    // Default selection resolves to index 0 (no explicit mode chosen yet).
    expect(dropdowns.single.value, 'Mode A');
  });

  testWidgets(
      'read_mode_hidden_when_no_modes: Read Mode row absent for empty modes',
      (tester) async {
    await _pumpPanel(
      tester,
      _caps(readoutModes: const []),
    );

    final readModeDropdowns = tester
        .widgetList<DropdownRow>(find.byType(DropdownRow))
        .where((d) => d.label == 'Read mode');
    expect(readModeDropdowns, isEmpty,
        reason:
            'Read Mode row must be hidden entirely when the camera reports no '
            'readout modes (hide-when-unsupported pattern).');
  });

  testWidgets('read mode selection persists only when the driver accepts it',
      (tester) async {
    final backend = mockBackend();
    when(
      () => backend.cameraSetReadoutMode(_kDeviceId, 1),
    ).thenAnswer((_) async {});
    final handle = await pumpAppScreen(
      tester,
      const CameraPanel(colors: SkotiqColors.dark),
      backend: backend,
      extraOverrides: _overrides(
        _caps(readoutModes: const ['Mode A', 'Mode B']),
      ),
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    final row = tester
        .widgetList<DropdownRow>(find.byType(DropdownRow))
        .singleWhere((widget) => widget.label == 'Read mode');
    row.onChanged!('Mode B');
    await tester.pump();

    verify(() => backend.cameraSetReadoutMode(_kDeviceId, 1)).called(1);
    final settings = handle.container.read(exposureSettingsProvider);
    expect(settings.readoutModeIndex, 1);
    expect(settings.fastReadout, isTrue);
    expect(
      handle.container.read(exposureSettingsUserDirtyProvider),
      isTrue,
    );
  });

  testWidgets('rejected read mode rolls settings back and surfaces the error',
      (tester) async {
    final backend = mockBackend();
    when(
      () => backend.cameraSetReadoutMode(_kDeviceId, 1),
    ).thenThrow(Exception('unsupported mode'));
    final handle = await pumpAppScreen(
      tester,
      const CameraPanel(colors: SkotiqColors.dark),
      backend: backend,
      extraOverrides: _overrides(
        _caps(readoutModes: const ['Mode A', 'Mode B']),
      ),
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    final row = tester
        .widgetList<DropdownRow>(find.byType(DropdownRow))
        .singleWhere((widget) => widget.label == 'Read mode');
    row.onChanged!('Mode B');
    await tester.pump();

    final settings = handle.container.read(exposureSettingsProvider);
    expect(settings.readoutModeIndex, isNull);
    expect(settings.fastReadout, isFalse);
    expect(
      handle.container.read(exposureSettingsUserDirtyProvider),
      isFalse,
    );
    expect(find.textContaining('Failed to set read mode'), findsOneWidget);
  });

  testWidgets('stale saved read mode is shown as unselected, not remapped',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CameraPanel(colors: SkotiqColors.dark),
      extraOverrides: [
        ..._overrides(_caps(readoutModes: const ['Mode A', 'Mode B'])),
        exposureSettingsProvider.overrideWith(
          (ref) => const ExposureSettings(
            exposureTime: 120,
            gain: 100,
            offset: 50,
            readoutModeIndex: 4,
          ),
        ),
      ],
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    final row = tester
        .widgetList<DropdownRow>(find.byType(DropdownRow))
        .singleWhere((widget) => widget.label == 'Read mode');
    expect(row.value, isNull);
    expect(
      handle.container.read(exposureSettingsProvider).readoutModeIndex,
      4,
    );
  });

  testWidgets('Warm up starts the gradual ramp instead of disabling cooling',
      (tester) async {
    final backend = mockBackend();
    when(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    ).thenAnswer((_) async {});
    // A working cooler holding a cold sensor: the only kind there is
    // anything to warm.
    when(() => backend.getCameraStatus(_kDeviceId)).thenAnswer(
      (_) async => const CameraStatus(
        connected: true,
        state: CameraState.idle,
        sensorTemp: -5,
        coolerPower: 40,
        targetTemp: -10,
        coolerOn: true,
        gain: 0,
        offset: 0,
        binX: 1,
        binY: 1,
        sensorWidth: 100,
        sensorHeight: 100,
        pixelSizeX: 3.76,
        pixelSizeY: 3.76,
        maxAdu: 65535,
        canCool: true,
        canSetGain: true,
        canSetOffset: true,
      ),
    );

    final handle = await pumpAppScreen(
      tester,
      const CameraPanel(colors: SkotiqColors.dark),
      backend: backend,
      extraOverrides: _overrides(_caps()),
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    await tester.tap(find.text('Warm up'));
    await tester.pump();
    await tester.pump();

    verify(
      () => backend.cameraSetCooling(
        deviceId: _kDeviceId,
        enabled: true,
        targetTemp: -5,
      ),
    ).called(1);
    verifyNever(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: false,
        targetTemp: any(named: 'targetTemp'),
      ),
    );
    expect(handle.container.read(cameraStateProvider).isWarming, isTrue);
    expect(find.text('Cancel warm-up'), findsOneWidget);

    handle.container.read(deviceServiceProvider).cancelWarmCamera();
    await tester.pump();
  });

  testWidgets('Warm up on a camera whose cooler is off sends nothing',
      (tester) async {
    final backend = mockBackend();
    when(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    ).thenAnswer((_) async {});
    when(() => backend.getCameraStatus(_kDeviceId)).thenAnswer(
      (_) async => const CameraStatus(
        connected: true,
        state: CameraState.idle,
        sensorTemp: 11.1,
        coolerPower: 0,
        targetTemp: 20,
        coolerOn: false,
        gain: 0,
        offset: 0,
        binX: 1,
        binY: 1,
        sensorWidth: 100,
        sensorHeight: 100,
        pixelSizeX: 3.76,
        pixelSizeY: 3.76,
        maxAdu: 65535,
        canCool: true,
        canSetGain: true,
        canSetOffset: true,
      ),
    );

    final handle = await pumpAppScreen(
      tester,
      const CameraPanel(colors: SkotiqColors.dark),
      backend: backend,
      extraOverrides: _overrides(_caps()),
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    await tester.tap(find.text('Warm up'));
    await tester.pump();
    await tester.pump();

    verifyNever(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    );
    expect(handle.container.read(cameraStateProvider).isWarming, isFalse);
    expect(
      find.text('The cooler is already off; there is nothing to warm.'),
      findsOneWidget,
    );
  });

  testWidgets('late cooling result from the old host is discarded',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    final resultA = Completer<void>();
    when(
      () => hostA.cameraSetCooling(
        deviceId: _kDeviceId,
        enabled: true,
        targetTemp: any(named: 'targetTemp'),
      ),
    ).thenAnswer((_) => resultA.future);
    late _SwappableBackendNotifier notifier;

    final handle = await pumpAppScreen(
      tester,
      const CameraPanel(colors: SkotiqColors.dark),
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          notifier = _SwappableBackendNotifier(ref, hostA);
          return notifier;
        }),
        ..._overrides(_caps()),
      ],
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    await tester.tap(find.text('Cool down'));
    await tester.pump();
    expect(find.text('Setting...'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    expect(find.text('Cool down'), findsOneWidget);

    resultA.complete();
    await tester.pump();
    expect(handle.container.read(coolingSettingsProvider).enabled, isFalse);
    expect(handle.container.read(cameraStateProvider).isCooling, isFalse);
    expect(find.text('Cool down'), findsOneWidget);
  });
}
