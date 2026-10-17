// C2 — Route the shared DeviceConnectionMixin connect path (profile editor /
// other equipment surfaces) through the guided connection troubleshooter.
//
// Scope: extend DeviceConnectionMixin.connectDevice so a *second* equipment
// connect surface (the profile editor dialog and any other consumer of the
// mixin) recovers via [ConnectionTroubleshooterDialog] instead of the bare
// "Failed to connect $deviceName: $e" snackbar — but only when the caller opts
// in by supplying both `deviceType` and `driverType`. Legacy callers that pass
// neither keep the exact snackbar behavior, so the upgrade is non-breaking.
//
// Coverage:
//   (a) WITHOUT deviceType/driverType + a throwing connectFn → the legacy
//       snackbar text appears and NO troubleshooter dialog is shown.
//   (b) WITH deviceType + driverType + a throwing connectFn → the
//       troubleshooter dialog is shown (no legacy snackbar).
//   (c) Pressing "Retry connection" re-invokes connectFn exactly once.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/mixins/device_connection_mixin.dart';
import 'package:skotiq_app/widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A representative ASCOM COM failure: CoCreateInstance returned `0x80040154`
/// (class not registered). The troubleshooter classifies this under
/// [DiagnosticCategory.driver] and shows the friendly driver headline.
const String _ascomClassNotRegistered = '0x80040154 Class not registered';

/// Friendly headline the troubleshooter shows for the driver category. Kept in
/// sync with `_headlineFor(DiagnosticCategory.driver)` in
/// `connection_diagnostic.dart`.
const String _driverHeadline = "The driver isn't responding";

/// A minimal host widget that mixes in [DeviceConnectionMixin] and exposes a
/// single button that drives [connectDevice] with caller-controlled inputs.
/// This is the smallest possible consumer of the mixin — it stands in for the
/// profile editor / any other equipment connect surface.
class _MixinHost extends ConsumerStatefulWidget {
  const _MixinHost({
    required this.connectFn,
    this.deviceType,
    this.driverType,
  });

  static const String deviceId = 'ascom:ASCOM.Simulator.Camera';
  static const String deviceName = 'ASCOM Camera Simulator';

  final Future<void> Function(String) connectFn;
  final DeviceType? deviceType;
  final DriverType? driverType;

  @override
  ConsumerState<_MixinHost> createState() => _MixinHostState();
}

class _MixinHostState extends ConsumerState<_MixinHost>
    with DeviceConnectionMixin<_MixinHost> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SkotiqButton(
          label: 'Connect',
          onPressed: () => connectDevice(
            deviceId: _MixinHost.deviceId,
            deviceName: _MixinHost.deviceName,
            connectFn: widget.connectFn,
            deviceType: widget.deviceType,
            driverType: widget.driverType,
          ),
        ),
      ),
    );
  }
}

Future<void> _pumpHost(WidgetTester tester, _MixinHost host) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: host,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('DeviceConnectionMixin.connectDevice troubleshooter routing', () {
    testWidgets(
        '(a) legacy caller (no deviceType/driverType) shows the bare snackbar '
        'and NO troubleshooter dialog', (tester) async {
      await _pumpHost(
        tester,
        _MixinHost(
          connectFn: (_) async => throw _ascomClassNotRegistered,
        ),
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Connect'));
      // Bounded pumps: the in-flight connect drives the button's loading
      // spinner (a continuous animation) so pumpAndSettle would never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The legacy snackbar text appears verbatim.
      expect(
        find.text(
          'Failed to connect ASCOM Camera Simulator: $_ascomClassNotRegistered',
        ),
        findsOneWidget,
      );
      // No troubleshooter dialog was shown.
      expect(find.byType(ConnectionTroubleshooterDialog), findsNothing);
    });

    testWidgets(
        '(b) opted-in caller (deviceType + driverType) shows the '
        'troubleshooter dialog and NOT the legacy snackbar', (tester) async {
      await _pumpHost(
        tester,
        _MixinHost(
          connectFn: (_) async => throw _ascomClassNotRegistered,
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
        ),
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The troubleshooter dialog is shown with the friendly driver headline.
      expect(find.byType(ConnectionTroubleshooterDialog), findsOneWidget);
      expect(find.text(_driverHeadline), findsOneWidget);
      // The raw driver string is preserved (collapsed behind Technical details).
      expect(find.text('Technical details'), findsOneWidget);
      // The legacy snackbar is NOT shown for opted-in callers.
      expect(
        find.text(
          'Failed to connect ASCOM Camera Simulator: $_ascomClassNotRegistered',
        ),
        findsNothing,
      );
    });

    testWidgets(
        '(c) pressing "Retry connection" re-invokes connectFn exactly once',
        (tester) async {
      var connectCalls = 0;
      await _pumpHost(
        tester,
        _MixinHost(
          connectFn: (_) async {
            connectCalls++;
            throw _ascomClassNotRegistered;
          },
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
        ),
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // First attempt failed → troubleshooter shown after one connect call.
      expect(find.byType(ConnectionTroubleshooterDialog), findsOneWidget);
      expect(connectCalls, 1);

      // Retry drives exactly one more connect attempt (bounded — single retry,
      // no recursion). The second failure falls back to the legacy snackbar
      // rather than re-opening the dialog.
      await tester.tap(find.widgetWithText(SkotiqButton, 'Retry connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(connectCalls, 2);
      // The single-retry contract: no second troubleshooter dialog, and the
      // bare snackbar surfaces the second failure.
      expect(find.byType(ConnectionTroubleshooterDialog), findsNothing);
      expect(
        find.text(
          'Failed to connect ASCOM Camera Simulator: $_ascomClassNotRegistered',
        ),
        findsOneWidget,
      );
    });
  });
}
