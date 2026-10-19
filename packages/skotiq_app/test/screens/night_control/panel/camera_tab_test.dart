// The Camera tab: cooler readouts and history, manual capture fields when
// idle, the run's step read-only during a run, filter slots, readout rows
// and a disconnected camera.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'panel_test_support.dart';

Finder _button(String label) => find.bySemanticsLabel(label);

void main() {
  testWidgets('the cooler block reads the camera and its history',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(board: NightFixtures.running()),
    );

    expect(find.text('Cooler · ASI1600MM'), findsOneWidget);
    expect(find.text('At setpoint'), findsOneWidget);
    expect(find.text('−10.0°'), findsNWidgets(2));
    expect(find.text('20%'), findsOneWidget);
    expect(find.byType(SeriesChart), findsOneWidget);
    expect(find.text('Sensor temperature since 19:20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle: the capture fields edit the manual settings',
      (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        camera: PanelFixtures.cameraIdle,
        ops: ops,
      ),
    );

    expect(find.text('for Snapshot and Loop'), findsOneWidget);
    expect(find.text('Edit in Sequencer'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, '5'), '10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(ops.lastExposure?.exposureTime, 10);
    expect(ops.lastExposure?.gain, 139);

    await tester.tap(_button('Dark'));
    await tester.pump();
    expect(ops.lastExposure?.frameType, FrameType.dark);

    await tester.tap(_button('2×2'));
    await tester.pump();
    expect(ops.lastExposure?.binningX, 2);
    expect(ops.lastExposure?.binningY, 2);
  });

  testWidgets('idle: a bad exposure is refused with a reason', (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        camera: PanelFixtures.cameraIdle,
        ops: ops,
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, '5'), '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Seconds above 0'), findsOneWidget);
    expect(ops.calls, isEmpty);
  });

  testWidgets('during a run the capture values are the step\'s, read-only',
      (tester) async {
    final ops = FakePanelOps();
    final container = ProviderContainer(
      overrides: panelOverrides(board: NightFixtures.running(), ops: ops),
    );
    addTearDown(container.dispose);
    final router = await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: const <Override>[],
      container: container,
    );

    expect(find.text('step 7'), findsOneWidget);
    expect(find.text('180'), findsOneWidget);
    expect(find.text('139'), findsOneWidget);
    // No editable capture field during a run: only the setpoint field,
    // itself disabled because the run owns the cooler.
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.every((f) => f.enabled == false), isTrue);

    await tester.tap(_button('Dark'));
    await tester.pump();
    expect(ops.calls, isEmpty);
    expect(
      tester.getSemantics(_button('Dark')),
      matchesSemantics(
        label: 'Dark',
        hint: "The run's step sets these values",
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Edit in Sequencer'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Edit in Sequencer'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNodeIdProvider), 'step-7');
    expect(routerLocation(router), '/sequencer');
  });

  testWidgets('during a run the filter slots are off and say why',
      (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(board: NightFixtures.running(), ops: ops),
    );

    expect(find.text('Ha · slot 5 of 8'), findsOneWidget);
    expect(find.text('Focus offset +40 from L'), findsOneWidget);
    await tester.ensureVisible(_button('Filter SII, slot 6'));
    await tester.tap(_button('Filter SII, slot 6'));
    await tester.pump();
    expect(ops.calls, isEmpty);
    expect(
      tester.getSemantics(_button('Filter SII, slot 6')),
      matchesSemantics(
        label: 'Filter SII, slot 6',
        hint: 'The run changes filters while it is loaded',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
      ),
    );
    expect(
      tester.getSemantics(_button('Filter Ha, slot 5')),
      matchesSemantics(
        label: 'Filter Ha, slot 5',
        hint: 'The run changes filters while it is loaded',
        isButton: true,
        hasEnabledState: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
  });

  testWidgets('idle: a filter slot moves the wheel', (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        camera: PanelFixtures.cameraIdle,
        ops: ops,
      ),
    );

    expect(find.text('L is the reference for focus offsets'), findsOneWidget);
    await tester.ensureVisible(_button('Filter Ha, slot 5'));
    await tester.tap(_button('Filter Ha, slot 5'));
    await tester.pump();
    expect(ops.calls, <String>['filter 4']);
  });

  testWidgets('the readout lists the sensor, folder and disk', (tester) async {
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(board: NightFixtures.running()),
    );

    await tester.scrollUntilVisible(
      find.text('639 GB free · ~11 nights'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('4656 × 3520 · 3.80 µm'), findsOneWidget);
    expect(find.text('/data/Skotiq/M74/Ha'), findsOneWidget);
    expect(find.textContaining('USB'), findsNothing);
  });

  testWidgets(
      'idle: the setpoint field cools, Warm up and Off reach the '
      'camera', (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        camera: PanelFixtures.cameraIdle,
        ops: ops,
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, '−10'), '−15');
    await tester.tap(_button('Cool to the setpoint'));
    await tester.pump();
    await tester.tap(_button('Warm up'));
    await tester.pump();
    await tester.tap(_button('Turn the cooler off'));
    await tester.pump();
    expect(ops.calls, <String>['setpoint -15.0', 'warmUp', 'coolerOff']);
  });

  testWidgets('a disconnected camera shows dashes and disabled controls',
      (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightCameraTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        camera: PanelFixtures.cameraDisconnected,
        coolerHistory: const NightSeriesVm(lines: <SeriesLineVm>[]),
        ops: ops,
      ),
    );

    expect(find.text('camera not connected'), findsOneWidget);
    expect(find.text('Cooler'), findsOneWidget);
    expect(find.byType(SeriesChart), findsNothing);
    expect(find.text('Filter wheel not connected'), findsOneWidget);
    await tester.tap(_button('Turn the cooler off'));
    await tester.pump();
    expect(ops.calls, isEmpty);
    expect(
      tester.getSemantics(_button('Cool to the setpoint')),
      matchesSemantics(
        label: 'Cool to the setpoint',
        hint: 'Camera not connected',
        isButton: true,
        hasEnabledState: true,
        hasSelectedState: true,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  group('nightCoolerState', () {
    const connected = DeviceConnectionState.connected;

    test('reads the camera snapshot', () {
      expect(
        nightCoolerState(const CameraStateSnapshot()),
        NightCoolerState.notConnected,
      );
      expect(
        nightCoolerState(const CameraStateSnapshot(connectionState: connected)),
        NightCoolerState.off,
      );
      expect(
        nightCoolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            isCooling: true,
            temperature: -9.7,
          ),
        ),
        NightCoolerState.atSetpoint,
      );
      expect(
        nightCoolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            isCooling: true,
            temperature: -7.4,
          ),
        ),
        NightCoolerState.cooling,
      );
      // Cooling with no temperature reading is not "at setpoint".
      expect(
        nightCoolerState(
          const CameraStateSnapshot(
              connectionState: connected, isCooling: true),
        ),
        NightCoolerState.cooling,
      );
      expect(
        nightCoolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            isCooling: true,
            isWarming: true,
          ),
        ),
        NightCoolerState.warming,
      );
    });
  });
}
