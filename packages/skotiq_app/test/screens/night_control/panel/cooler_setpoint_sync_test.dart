import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_tab.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('the cooler field follows the host unless a draft is unsent', (
    tester,
  ) async {
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: _Host(key: key),
        ),
      ),
    );
    await tester.pump();
    expect(_field(tester), '');

    key.currentState!.set(
      connected: true,
      coolerState: CoolerState.off,
      defaultSetpoint: -10,
    );
    await tester.pump();
    expect(_field(tester), '−10');

    key.currentState!.set(setpoint: -15, coolerState: CoolerState.cooling);
    await tester.pump();
    expect(_field(tester), '−15');

    await tester.enterText(find.byType(EditableText), '-12.5');
    await tester.pump();
    key.currentState!.set(setpoint: -20);
    await tester.pump();
    expect(_field(tester), '-12.5');

    key.currentState!.set(setpoint: -12.5);
    await tester.pump();
    key.currentState!.set(setpoint: -10);
    await tester.pump();
    expect(_field(tester), '−10');
  });
}

String _field(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller.text;

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  var connected = false;
  var coolerState = CoolerState.notConnected;
  double? setpoint;
  double? defaultSetpoint;

  void set({
    bool? connected,
    CoolerState? coolerState,
    double? setpoint,
    double? defaultSetpoint,
    bool clearSetpoint = false,
  }) {
    setState(() {
      this.connected = connected ?? this.connected;
      this.coolerState = coolerState ?? this.coolerState;
      if (clearSetpoint) {
        this.setpoint = null;
      } else if (setpoint != null) {
        this.setpoint = setpoint;
      }
      if (defaultSetpoint != null) this.defaultSetpoint = defaultSetpoint;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NightCoolerSection(
        vm: NightCameraPanelVm(
          canCommand: true,
          runLive: false,
          connected: connected,
          coolerState: coolerState,
          filters: const NightFilterSlotsVm(connected: false),
          setpoint: setpoint,
          defaultSetpoint: defaultSetpoint,
        ),
        history: const NightSeriesVm(lines: []),
      ),
    );
  }
}
