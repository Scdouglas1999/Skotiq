import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/cloud_motion_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets(
      'surfaces an honest "unavailable" line with the reason when no motion',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const RunDashboardCloudMotionPanel(),
      overrides: [
        inMemoryDatabaseOverride(),
        cloudCoverPercentageProvider.overrideWith((ref) async => 80.0),
        analyzeCloudMotionDetailedProvider.overrideWith(
          (ref) async => const CloudMotionResult.unavailable(
            CloudMotionUnavailableReason.noSpatialData,
          ),
        ),
      ],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The silent "No prediction" arrival row is still present, but it is now
    // accompanied by an explicit reason so the operator knows the predictive
    // pause is not available.
    expect(find.text('No prediction'), findsOneWidget);
    expect(
      find.text('Cloud-motion unavailable: no spatial radar data'),
      findsOneWidget,
    );
  });

  testWidgets('maps each unavailable reason to its own honest label',
      (tester) async {
    const cases = <CloudMotionUnavailableReason, String>{
      CloudMotionUnavailableReason.insufficientFrames:
          'Cloud-motion unavailable: not enough radar frames yet',
      CloudMotionUnavailableReason.noCloudsDetected:
          'Cloud-motion unavailable: no clouds to track (clear sky)',
      CloudMotionUnavailableReason.noSpatialData:
          'Cloud-motion unavailable: no spatial radar data',
      CloudMotionUnavailableReason.noResolvableMotion:
          'Cloud-motion unavailable: clouds not moving enough to predict',
    };

    for (final entry in cases.entries) {
      await tester.pumpWidget(ProviderScope(
        // Fresh key per iteration so the panel subtree is rebuilt from scratch
        // rather than reusing the previous iteration's settled AsyncValue.
        key: ValueKey(entry.key),
        overrides: [
          inMemoryDatabaseOverride(),
          cloudCoverPercentageProvider.overrideWith((ref) async => 50.0),
          analyzeCloudMotionDetailedProvider.overrideWith(
            (ref) async => CloudMotionResult.unavailable(entry.key),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: RunDashboardCloudMotionPanel()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(entry.value), findsOneWidget,
          reason: 'reason ${entry.key} should render "${entry.value}"');
    }
  });

  testWidgets('shows the prediction and no unavailable line when motion exists',
      (tester) async {
    final motion = CloudMotion(
      speedKmh: 30,
      directionDegrees: 180,
      distanceKm: 40,
      etaToLocation: const Duration(minutes: 80),
      calculatedAt: DateTime.now().toUtc(),
    );

    await tester.pumpWidget(_wrap(
      const RunDashboardCloudMotionPanel(),
      overrides: [
        inMemoryDatabaseOverride(),
        cloudCoverPercentageProvider.overrideWith((ref) async => 10.0),
        analyzeCloudMotionDetailedProvider.overrideWith(
          (ref) async => CloudMotionResult.available(motion),
        ),
      ],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('80 min'), findsOneWidget);
    expect(find.textContaining('Cloud-motion unavailable'), findsNothing);
  });
}
