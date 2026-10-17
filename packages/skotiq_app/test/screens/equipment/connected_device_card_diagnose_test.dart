// Integration test: the connected-device card must surface the
// troubleshooter-backed error subtitle AND a Diagnose affordance when its
// device is in `DeviceConnectionState.error`, and tapping Diagnose must open
// the full ConnectionTroubleshooterDialog.
//
// This is the production-wiring counterpart to device_error_subtitle_test.dart
// (which exercises the subtitle widget in isolation). Here we drive the real
// card through the real device-state provider so a regression that unwired the
// subtitle — the exact defect this test guards against — fails loudly.
//
// We use the safety-monitor device type because it renders no quick-action
// buttons; that keeps the card's fixed-width (320px) action row from
// overflowing under the wide default test font, so the test isolates the C4
// header/subtitle wiring it is meant to verify rather than tripping on the
// pre-existing action-row layout of action-heavy device types.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_app/widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The connection-troubleshooter knowledge base is deliberately kept out of the
// skotiq_core barrel; import the source path directly (mirroring the
// widget under test and connection_troubleshooter_dialog.dart).
// ignore: implementation_imports
import 'package:skotiq_core/src/models/troubleshooter/connection_diagnostic.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Pumps the card inside an [UncontrolledProviderScope] backed by [container]
/// so the test can drive the device-state notifier directly (e.g. push the
/// safety monitor into the error state) and observe the card react.
Future<void> _pumpCard(
  WidgetTester tester,
  ProviderContainer container,
) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: const Scaffold(
          body: ConnectedDeviceCard(type: ConnectedDeviceType.safetyMonitor),
        ),
      ),
    ),
  );
}

void main() {
  group('ConnectedDeviceCard — Diagnose wiring', () {
    testWidgets('healthy card renders no error subtitle and no Diagnose button',
        (tester) async {
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);
      await _pumpCard(tester, container);

      // Drive the device into a healthy connected state.
      final notifier = container.read(safetyMonitorStateProvider.notifier);
      notifier.setConnecting('ascom:ASCOM.MySafety.SafetyMonitor', 'Roof');
      notifier.setConnected();
      await tester.pumpAndSettle();

      expect(find.text('Diagnose'), findsNothing);
      expect(find.byType(ConnectionTroubleshooterDialog), findsNothing);
    });

    testWidgets(
        'errored card shows the troubleshooter headline + Diagnose, and tapping '
        'Diagnose opens the troubleshooter dialog', (tester) async {
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);
      await _pumpCard(tester, container);

      const raw =
          'CoCreateInstance failed: Class not registered (0x80040154) for '
          'ASCOM.MySafety.SafetyMonitor';

      // Drive the device into the error state with a real ASCOM-class failure.
      final notifier = container.read(safetyMonitorStateProvider.notifier);
      notifier.setConnecting('ascom:ASCOM.MySafety.SafetyMonitor', 'Roof');
      notifier.setError(raw);
      await tester.pumpAndSettle();

      // The friendly classifier headline appears inline (NOT the raw string).
      // The card resolves DriverType from the `ascom:` device-id prefix.
      final diagnosis = diagnoseConnectionFailure(
        deviceType: DeviceType.safetyMonitor,
        driverType: DriverType.ascom,
        rawError: raw,
      );
      expect(diagnosis.category, DiagnosticCategory.driver);
      expect(find.text(diagnosis.headline), findsOneWidget);
      expect(find.text(raw), findsNothing);

      // The Diagnose affordance is present.
      final diagnose = find.text('Diagnose');
      expect(diagnose, findsOneWidget);

      // Tapping Diagnose opens the full troubleshooter dialog, classified the
      // same way (driver headline) with the raw error behind Technical details.
      await tester.tap(diagnose);
      await tester.pumpAndSettle();

      expect(find.byType(ConnectionTroubleshooterDialog), findsOneWidget);
      expect(find.text(diagnosis.headline), findsWidgets);
      expect(find.text('Technical details'), findsOneWidget);
    });
  });
}
