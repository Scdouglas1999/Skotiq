import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/imaging/widgets/calibration_section.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';

/// Build a GoRouter that hosts the calibration section so the
/// "Go to Equipment" button has a real `/equipment` route to navigate to
/// when tapped.
GoRouter _buildRouter() {
  return GoRouter(
    initialLocation: '/imaging',
    routes: [
      GoRoute(
        path: '/imaging',
        builder: (context, state) {
          final colors = SkotiqColors.of(context);
          return Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: CalibrationSection(colors: colors),
            ),
          );
        },
      ),
      GoRoute(
        path: '/equipment',
        builder: (_, __) =>
            const Scaffold(body: Text('equipment stub for test')),
      ),
    ],
  );
}

void main() {
  testWidgets(
    'CalibrationSection disables all controls when no camera is connected',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: _buildRouter(),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('Image calibration'), findsOneWidget);

      // Status block surfaces the disabled-reason copy.
      expect(
        find.textContaining('Connect a camera to manage its defect map.'),
        findsWidgets,
      );

      // The Build button is rendered, but disabled.
      final buildButton = tester.widget<SmallButton>(
        find.widgetWithText(SmallButton, 'Build defect map...'),
      );
      expect(
        buildButton.isEnabled,
        isFalse,
        reason: 'Build button must be disabled when no camera is connected',
      );

      // The Clear button is rendered, but disabled.
      final clearButton = tester.widget<SmallButton>(
        find.widgetWithText(SmallButton,
            'Clear defect map for this camera at this temperature'),
      );
      expect(
        clearButton.isEnabled,
        isFalse,
        reason: 'Clear button must be disabled when no camera is connected',
      );

      // The "Apply during capture" toggle is rendered, but disabled.
      // The widget is `SkotiqSwitch` (not the Material `Switch`) — the
      // calibration section uses the design-system component, so the test
      // queries that type. `enabled: false` AND `onChanged == null` both
      // disable a SkotiqSwitch, and we assert the second since it's
      // the canonical "this is wired up to a handler" signal the row
      // toggles when a camera connects.
      expect(find.text('Apply during capture'), findsOneWidget);
      final applySwitch = tester.widget<SkotiqSwitch>(
        find.widgetWithText(Row, 'Apply during capture').evaluate().isNotEmpty
            ? find.descendant(
                of: find.widgetWithText(Row, 'Apply during capture').first,
                matching: find.byType(SkotiqSwitch),
              )
            : find.byType(SkotiqSwitch).first,
      );
      expect(applySwitch.onChanged, isNull,
          reason: 'Apply toggle must be disabled when no camera is connected');
      expect(applySwitch.value, isFalse,
          reason:
              'Apply toggle defaults to off when no defect map status is known');

      // The disabled state surfaces a Tooltip explaining the reason.
      final tooltipFinder = find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            (w.message ?? '')
                .contains('Connect a camera to manage its defect map.'),
      );
      expect(
        tooltipFinder,
        findsWidgets,
        reason:
            'Each disabled control must surface a Tooltip explaining why it '
            'is disabled.',
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CalibrationSection surfaces a "Go to Equipment" button when no camera '
    'is connected',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: _buildRouter(),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.widgetWithText(SkotiqButton, 'Go to Equipment'),
        findsOneWidget,
        reason: 'No-camera empty state must expose a one-click escape '
            'into the Equipment screen.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CalibrationSection offers the "Use {nearest}°C map" chip when a '
    'different temperature bucket has a stored map',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const cameraId = 'native:zwo:ASI2600MC';
      const cameraName = 'ZWO ASI2600MC';
      const sensorWidth = 6248;
      const sensorHeight = 4176;
      const currentTempC = -10.0;
      const alternateBucketC = -15.0;

      DefectMapStatus? fakeStatusFor(DefectMapQuery query) {
        final bucket = DefectMapTemperatureBucket.fromCelsius(
            query.sensorTemperatureCelsius);
        // Only the -15C bucket has a stored map. The current -10C bucket
        // returns null, which is what triggers the alternate-bucket chip.
        if (bucket ==
            DefectMapTemperatureBucket.fromCelsius(alternateBucketC)) {
          return DefectMapStatus(
            cameraId: cameraId,
            width: sensorWidth,
            height: sensorHeight,
            temperatureBucket: bucket,
            defectivePixelCount: 1243,
            lastRebuiltUnixSeconds:
                DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000,
            applyDuringCapture: false,
            storedOnDisk: true,
          );
        }
        return null;
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            cameraStateProvider.overrideWith((ref) {
              final notifier = CameraStateNotifier(ref);
              notifier
                ..setConnecting(cameraId, cameraName)
                ..setConnected()
                ..updateTemperature(currentTempC, 0.65);
              return notifier;
            }),
            cameraCapabilitiesProvider(cameraId).overrideWith(
              (ref) async => const CameraCapabilities(
                maxWidth: sensorWidth,
                maxHeight: sensorHeight,
                bitDepth: 16,
                canSetCcdTemperature: true,
                canSetCooler: true,
                canGetCoolerPower: true,
                pixelSizeX: 3.76,
                pixelSizeY: 3.76,
                bayerPattern: 'RGGB',
              ),
            ),
            defectMapStatusProvider.overrideWith((ref, query) async {
              return fakeStatusFor(query);
            }),
          ],
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: _buildRouter(),
          ),
        ),
      );

      // Allow the FutureProviders (capabilities + alternate-bucket probes)
      // to resolve. The widget probes outward from the current bucket so
      // multiple frames may be needed before the chip appears.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        find.textContaining('No defect map for $cameraName at -10.0C'),
        findsOneWidget,
        reason: 'Empty-state copy should name the connected camera and the '
            'current temperature bucket.',
      );
      expect(
        find.textContaining('Capture 20+ dark frames at this temperature'),
        findsOneWidget,
        reason: 'Build-from-darks hint must be visible.',
      );
      expect(
        find.textContaining('A map exists for -15.0C'),
        findsOneWidget,
        reason: 'Alternate-bucket chip must call out the existing bucket.',
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Use -15.0C map'),
        findsOneWidget,
        reason: 'A one-click button must accept the alternate map.',
      );

      final applySwitch = tester.widget<SkotiqSwitch>(
        find.descendant(
          of: find.widgetWithText(Row, 'Apply during capture').first,
          matching: find.byType(SkotiqSwitch),
        ),
      );
      expect(
        applySwitch.onChanged,
        isNull,
        reason: 'A neighbouring map must not enable the current bucket toggle.',
      );

      expect(tester.takeException(), isNull);

      await settleProviderTeardown(tester);
    },
  );
}
