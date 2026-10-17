// Optical Train Diagnostics must not grade "no data" as a healthy optical train.
//
// Observed defect: a session with zero psf_field_tiles and zero astrometric
// residual vectors rendered "Optical Health: A / Excellent", bars Tilt 0 and
// Collimation 0, a Tilt card badged "Within range" reading "Score 0.0: tilt
// looks controlled for this session.", and a Collimation card badged "Centered"
// reading "Center and edge behavior look balanced for this session." — directly
// beside its own "0 tiles" / "0 vectors" panels and a "No diagnostics data"
// findings card. The penalty scores are 0 when nothing was measured, and 0 is
// the BEST possible penalty, so "not measured" scored identically to "perfect".
// A user who came here suspecting tilt read a green A and stopped looking.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/diagnostics/diagnostics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const int _sessionId = 4;

class _ActiveSession extends SessionStateNotifier {
  _ActiveSession(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const SessionState(isActive: true, dbSessionId: _sessionId);
  }
}

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'Night D - V-Test',
      startTime: DateTime.utc(2026, 7, 25, 21),
      totalExposures: 120,
      successfulExposures: 120,
      failedExposures: 0,
      totalIntegrationSecs: 3600,
      autofocusCount: 0,
      status: 'completed',
    );

List<Override> _overrides({
  required List<PsfFieldTileRow> tiles,
  required List<AstrometryResidualVectorRow> residuals,
}) =>
    [
      allSessionsProvider.overrideWith(
        (ref) => Stream<List<ImagingSession>>.value([_session()]),
      ),
      sessionStateProvider.overrideWith((ref) => _ActiveSession(ref)),
      sessionPsfTilesProvider.overrideWith((ref, id) => Stream.value(tiles)),
      sessionResidualVectorsProvider.overrideWith(
        (ref, id) => Stream.value(residuals),
      ),
    ];

PsfFieldTileRow _tile(int index, {required double eccentricity}) =>
    PsfFieldTileRow(
      id: index + 1,
      capturedImageId: 1,
      sessionId: _sessionId,
      tileRow: index ~/ 3,
      tileCol: index % 3,
      starCount: 40,
      medianFwhm: 3.0,
      medianHfr: 1.5,
      medianEccentricity: eccentricity,
      roundness: 0.9,
      timestamp: DateTime.utc(2026, 7, 25, 22),
    );

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a session with no PSF tiles reports "Not measured", not an A',
      (tester) async {
    await pumpAppScreen(
      tester,
      const DiagnosticsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: _overrides(tiles: const [], residuals: const []),
    );
    await _drain(tester);

    // The grade itself.
    expect(find.text('Not measured'), findsWidgets);
    expect(find.text('Excellent'), findsNothing);
    expect(find.text('A'), findsNothing);

    // …and the two per-axis verdicts that contradicted the "0 tiles" panels.
    expect(find.text('Within range'), findsNothing);
    expect(find.text('Centered'), findsNothing);
    expect(
      find.textContaining('tilt looks controlled for this session'),
      findsNothing,
    );
    expect(
      find.textContaining('Center and edge behavior look balanced'),
      findsNothing,
    );
  });

  testWidgets('a session that WAS measured still gets its grade and verdicts',
      (tester) async {
    // A flat, well-behaved field: nine tiles at the same low eccentricity, so
    // the tilt penalty is genuinely near zero and the green verdict is earned.
    await pumpAppScreen(
      tester,
      const DiagnosticsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: _overrides(
        tiles: [for (var i = 0; i < 9; i++) _tile(i, eccentricity: 0.20)],
        residuals: const [],
      ),
    );
    await _drain(tester);

    expect(find.text('Within range'), findsOneWidget);
    expect(
      find.textContaining('tilt looks controlled for this session'),
      findsOneWidget,
    );
  });
}
