// Equipment-screen connect failures route through the guided connection
// troubleshooter.
//
// When a device the user picked in the discovery panel fails to connect, the
// bare "Failed to connect: $e" snackbar is replaced by
// [ConnectionTroubleshooterDialog], which turns the raw driver string into a
// plain-language, hardware-aware remediation playbook while preserving that
// string verbatim in its collapsible "Technical details" section.
//
// Two layers of coverage:
//   1. `DiscoveryPanel.showConnectionTroubleshooter` (the @visibleForTesting
//      orchestration seam): the correct driver type / raw error are derived
//      from the backend the user actually tried, the dialog is shown with the
//      friendly headline for the driver/usb category, and pressing
//      "Retry connection" resolves the future to `true`.
//   2. The end-to-end connect path through the real [DiscoveryPanel], which
//      delegates to the shared [DeviceConnectionMixin.connectDevice]: a failing
//      `connectCamera` opens the troubleshooter, and pressing "Retry
//      connection" drives exactly one more (bounded) connect attempt. The
//      mixin's single-retry contract means the second failure falls back to the
//      bare snackbar rather than re-opening the dialog — bounded by
//      construction, no unbounded recursion.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/discovery_panel.dart';
import 'package:skotiq_app/widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A representative ASCOM COM failure: CoCreateInstance returned
/// `0x80040154` (class not registered) — the driver isn't installed/registered.
/// The troubleshooter classifies this under [DiagnosticCategory.driver].
const String _ascomClassNotRegistered = '0x80040154 Class not registered';

/// Friendly headline the troubleshooter shows for the driver category. Kept in
/// sync with `_headlineFor(DiagnosticCategory.driver)` in
/// `connection_diagnostic.dart`.
const String _driverHeadline = "The driver isn't responding";

UnifiedDevice _ascomCamera({String id = 'ascom:ASCOM.Simulator.Camera'}) {
  return UnifiedDevice(
    canonicalName: 'ascom camera',
    displayName: 'ASCOM Camera Simulator',
    type: DeviceType.camera,
    availableBackends: {
      DriverType.ascom: DeviceInfo(
        id: id,
        name: 'ASCOM Camera Simulator',
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        description: '',
        driverVersion: '',
      ),
    },
  );
}

/// A [DeviceService] whose `connectCamera` always throws a fixed error and
/// records how many times it was invoked. Everything else is inherited from
/// the real service (constructed against a stubbed [MockBackend]); the connect
/// flow under test only ever reaches `connectCamera`.
class _ThrowingDeviceService extends DeviceService {
  _ThrowingDeviceService(super.ref, super.backend, this.error);

  final Object error;
  int connectCameraCalls = 0;

  @override
  Future<void> connectCamera(String deviceId) async {
    connectCameraCalls++;
    throw error;
  }
}

/// `SkotiqIconButton` carries its tooltip through `Semantics` and
/// `SkotiqTooltip`, not a Material `Tooltip`, so `find.byTooltip` misses it.
Finder _iconButton(String tooltip) => find.byWidgetPredicate(
      (w) => w is SkotiqIconButton && w.tooltip == tooltip,
    );

void main() {
  group('DiscoveryPanel.showConnectionTroubleshooter', () {
    testWidgets(
        'shows the troubleshooter with the friendly driver headline for an '
        'ASCOM class-not-registered failure', (tester) async {
      late BuildContext capturedContext;
      Future<bool>? showFuture;

      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      showFuture = DiscoveryPanel.showConnectionTroubleshooter(
        capturedContext,
        _ascomCamera(),
        _ascomClassNotRegistered,
      );
      await tester.pumpAndSettle();

      // The dialog is on screen, found by type.
      expect(find.byType(ConnectionTroubleshooterDialog), findsOneWidget);
      // The friendly, plain-language headline for the driver category appears.
      expect(find.text(_driverHeadline), findsOneWidget);
      // The raw driver string is never thrown away — the troubleshooter keeps
      // it reachable (collapsed, behind "Technical details").
      expect(find.text('Technical details'), findsOneWidget);

      // Pressing "Retry connection" resolves the future to true.
      await tester
          .tap(find.widgetWithText(SkotiqButton, 'Retry connection'));
      await tester.pumpAndSettle();
      expect(await showFuture, isTrue);
    });

    testWidgets('Close resolves the future to false (no retry)',
        (tester) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final showFuture = DiscoveryPanel.showConnectionTroubleshooter(
        capturedContext,
        _ascomCamera(),
        _ascomClassNotRegistered,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SkotiqButton, 'Close'));
      await tester.pumpAndSettle();
      expect(await showFuture, isFalse);
    });
  });

  group('DiscoveryPanel connect-failure → troubleshooter → retry', () {
    testWidgets(
        'a failing connect opens the troubleshooter, and Retry drives exactly '
        'one more (bounded) connect attempt before falling back to the snackbar',
        (tester) async {
      final backend = mockBackend();
      addTearDown(backend.dispose);

      late _ThrowingDeviceService deviceService;

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          deviceServiceProvider.overrideWith((ref) {
            deviceService = _ThrowingDeviceService(
              ref,
              backend,
              _ascomClassNotRegistered,
            );
            return deviceService;
          }),
          unifiedDiscoveryProvider.overrideWith(
            (ref) => _SeededDiscoveryNotifier(
              ref,
              UnifiedDiscoveryState(groupedDevices: [_ascomCamera()]),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: SingleChildScrollView(child: DiscoveryPanel()),
            ),
          ),
        ),
      );
      await tester.pump();

      // Expand the discovery panel so the device rows (and their Connect
      // buttons) are laid out.
      await tester.tap(_iconButton('Expand'));
      await tester.pumpAndSettle();

      final connectButton =
          find.widgetWithText(SkotiqButton, 'Connect').first;
      expect(connectButton, findsOneWidget);

      await tester.tap(connectButton);
      // Bounded pumps rather than pumpAndSettle: the in-flight connect drives a
      // loading spinner on the Connect button, whose continuous animation would
      // make pumpAndSettle never settle. A couple of frames is enough for the
      // (synchronously-throwing) connect to fail and the dialog route to push.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // First attempt failed → troubleshooter is shown.
      expect(find.byType(ConnectionTroubleshooterDialog), findsOneWidget);
      expect(find.text(_driverHeadline), findsOneWidget);
      expect(deviceService.connectCameraCalls, 1);

      // Retry → the dialog closes and the shared mixin re-attempts the connect
      // exactly once. The second attempt fails too; the mixin's single-retry
      // contract then surfaces the bare snackbar rather than re-opening the
      // troubleshooter (bounded by construction — no unbounded recursion).
      await tester
          .tap(find.widgetWithText(SkotiqButton, 'Retry connection'));
      // Let the dialog's exit transition finish and the second connect attempt
      // fail. The dialog route's fade is ~150ms; pump well past it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The retry drove exactly one more connect attempt (bounded — single
      // retry).
      expect(deviceService.connectCameraCalls, 2);
      // The troubleshooter is NOT re-shown after the bounded retry fails.
      expect(find.byType(ConnectionTroubleshooterDialog), findsNothing);
      // The second failure falls back to the bare snackbar.
      expect(
        find.text(
          'Failed to connect ASCOM Camera Simulator: $_ascomClassNotRegistered',
        ),
        findsOneWidget,
      );
    });
  });
}

/// A [UnifiedDiscoveryNotifier] seeded with a fixed state for widget tests, so
/// the panel renders a known device list without running real discovery.
class _SeededDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _SeededDiscoveryNotifier(super.ref, UnifiedDiscoveryState seed) {
    state = seed;
  }
}
