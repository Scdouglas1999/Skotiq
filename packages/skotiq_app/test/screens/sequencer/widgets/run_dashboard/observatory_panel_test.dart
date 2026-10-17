import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/observatory_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('hides entirely when no observatory device is connected',
      (tester) async {
    // Most rigs have no dome/cover/switch. Rather than render a header plus a
    // "nothing connected" line that wastes a dashboard slot, the panel now
    // collapses to a zero-size box — matching the hide-when-empty pattern of
    // the equipment telemetry strip and the quality/forensics panels.
    await tester.pumpWidget(
      const ProviderScope(
        child:
            MaterialApp(home: Scaffold(body: RunDashboardObservatoryPanel())),
      ),
    );
    await tester.pump();

    expect(find.text('OBSERVATORY'), findsNothing);
    expect(find.text('No dome, cover, or switch connected.'), findsNothing);
    // The card collapses to SizedBox.shrink() — no SkotiqCard rendered.
    expect(find.byType(SkotiqCard), findsNothing);
  });

  testWidgets('renders dome shutter / azimuth / slaved when connected',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    final dome = container.read(domeStateProvider.notifier);
    dome.setConnecting('ascom:Dome.Sim', 'Sim Dome');
    dome.setConnected();
    dome.updateShutterStatus(ShutterStatus.open);
    dome.updateAzimuth(123.4);
    dome.setSlaved(true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RunDashboardObservatoryPanel()),
      ),
    );
    await tester.pump();

    expect(find.text('Dome'), findsOneWidget);
    // Shutter open is shown both as the status pill and the row value.
    expect(find.text('Open'), findsWidgets);
    expect(find.text('123.4°'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget); // slaved
    expect(find.text('No dome, cover, or switch connected.'), findsNothing);
  });

  testWidgets('renders cover + flat-light state when connected',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    final cover = container.read(coverCalibratorStateProvider.notifier);
    cover.setConnecting('ascom:Cover.Sim', 'Flip-Flat');
    cover.setConnected();
    cover.updateCoverStatus(CoverStatus.closed);
    cover.updateCalibratorStatus(CalibratorStatus.ready);
    cover.updateBrightness(140);
    cover.updateMaxBrightness(255);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RunDashboardObservatoryPanel()),
      ),
    );
    await tester.pump();

    expect(find.text('Cover / flat panel'), findsOneWidget);
    expect(find.text('Closed'), findsWidgets);
    expect(find.text('On'), findsWidgets); // calibrator ready
    expect(find.text('140/255'), findsOneWidget);
  });

  testWidgets('renders per-channel switch state with on/off counts',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    final sw = container.read(switchStateProvider.notifier);
    sw.setConnecting('ascom:Switch.Sim', 'Power Box');
    sw.setConnected();
    sw.setChannels(
      count: 3,
      names: ['Mount', 'Camera', 'Dew Heater'],
      states: [true, false, true],
      refreshedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RunDashboardObservatoryPanel()),
      ),
    );
    await tester.pump();

    expect(find.text('Switches'), findsOneWidget);
    expect(find.text('2/3 on'), findsOneWidget);
    expect(find.text('Mount'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Dew Heater'), findsOneWidget);
  });
}
