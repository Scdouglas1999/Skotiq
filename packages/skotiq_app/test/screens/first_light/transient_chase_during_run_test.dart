// Chase slews the mount to a First Light candidate. While a sequence owns the
// mount that slew would pull the scope off the run's target mid-exposure, so
// Chase refuses and names the run instead of offering a Slew confirmation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/widgets/transient_candidate_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FixedMount extends MountStateNotifier {
  _FixedMount(super.ref, MountState fixed) {
    state = fixed;
  }
}

class _RunProgress extends SequenceProgressNotifier {
  _RunProgress(SequenceProgress fixed) {
    state = fixed;
  }
}

const _connected = MountState(
  connectionState: DeviceConnectionState.connected,
  deviceId: 'mount-1',
  ra: 2.37,
  dec: 42.35,
);

TransientDetectionRow _detection() => TransientDetectionRow(
      id: 7,
      sessionId: 93,
      capturedImageId: 4120,
      tileId: 912743,
      detectedAt: DateTime.utc(2026, 10, 26, 5, 41),
      raDeg: 35.6377,
      decDeg: 42.3491,
      residualFlux: 1820.0,
      deltaMag: null,
      snr: 21.4,
      fwhm: 3.1,
      eccentricity: 0.18,
      positionAngleDeg: 12.0,
      kind: 'newSource',
      catalogMatch: null,
      confidence: 0.72,
      reviewed: false,
      dismissed: false,
    );

Future<void> _pumpCard(
  WidgetTester tester, {
  required SequenceExecutionState runState,
  String? runTarget,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mountStateProvider.overrideWith((ref) => _FixedMount(ref, _connected)),
        sequenceExecutionStateProvider.overrideWith((ref) => runState),
        sequenceProgressProvider.overrideWith(
          (ref) => _RunProgress(
            SequenceProgress(state: runState, currentTarget: runTarget),
          ),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: TransientCandidateCard(detection: _detection()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Chase is refused and names the run while a sequence runs', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      runState: SequenceExecutionState.running,
      runTarget: 'NGC 891',
    );

    await tester.tap(find.text('Chase'));
    await tester.pumpAndSettle();

    expect(find.text('Chase this candidate?'), findsNothing);
    expect(find.text('Slew'), findsNothing);
    expect(find.textContaining('A sequence is running on NGC 891'), findsOne);
  });

  testWidgets('a paused run still blocks Chase', (tester) async {
    await _pumpCard(tester, runState: SequenceExecutionState.paused);

    await tester.tap(find.text('Chase'));
    await tester.pumpAndSettle();

    expect(find.text('Chase this candidate?'), findsNothing);
    expect(find.textContaining('A sequence is running.'), findsOne);
  });

  testWidgets('with no run, Chase asks before slewing', (tester) async {
    await _pumpCard(tester, runState: SequenceExecutionState.idle);

    await tester.tap(find.text('Chase'));
    await tester.pumpAndSettle();

    expect(find.text('Chase this candidate?'), findsOne);
    expect(find.text('Slew'), findsOne);
  });
}
