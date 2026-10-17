// Analytics ▸ Diagnostics could only ever look at `imaging_sessions` rows.
//
// Loop / quick captures never open a session, so their PSF tiles and
// astrometry residuals are written with a NULL session_id. A night spent on
// quick captures therefore produced real optical-train measurements that the
// Diagnostics tab had no way to select — the picker offered nothing and the
// screen sat on "Select an imaging session to analyze" forever.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/diagnostics/diagnostics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

PsfFieldTileRow _tile({
  required int row,
  required int col,
  required double hfr,
}) {
  return PsfFieldTileRow(
    id: row * 10 + col,
    // The whole point: no session owns these tiles.
    sessionId: null,
    tileRow: row,
    tileCol: col,
    starCount: 30,
    medianFwhm: hfr * 2.35,
    medianHfr: hfr,
    medianEccentricity: 0.12,
    roundness: 0.9,
    timestamp: DateTime.utc(2026, 8, 11, 23, 0),
  );
}

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<Override> _overrides({required bool withQuickCaptureData}) {
  return [
    allSessionsProvider.overrideWith(
      (ref) => Stream<List<ImagingSession>>.value(const []),
    ),
    sessionlessPsfTilesProvider.overrideWith(
      (ref) => Stream<List<PsfFieldTileRow>>.value(
        withQuickCaptureData
            ? [
                _tile(row: 0, col: 0, hfr: 2.1),
                _tile(row: 0, col: 1, hfr: 3.4),
                _tile(row: 1, col: 0, hfr: 2.2),
                _tile(row: 1, col: 1, hfr: 3.6),
              ]
            : const [],
      ),
    ),
    sessionlessResidualVectorsProvider.overrideWith(
      (ref) => Stream<List<AstrometryResidualVectorRow>>.value(const []),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quick-capture frames are selectable and diagnosable',
      (tester) async {
    await pumpAppScreen(
      tester,
      const DiagnosticsScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _overrides(withQuickCaptureData: true),
    );
    await _drainAsyncFrames(tester);

    // The picker renders only the selected entry (or the hint) while closed,
    // so the offer is asserted with the menu open.
    expect(find.text('Select session'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();

    expect(
      find.text('Quick captures (no session)'),
      findsWidgets,
      reason: 'a night of quick captures must be offered by the picker',
    );

    await tester.tap(find.text('Quick captures (no session)').last);
    await _drainAsyncFrames(tester);

    expect(
      find.text('Select an imaging session to analyze'),
      findsNothing,
      reason: 'selecting the quick-capture bucket must open the diagnostics',
    );
    expect(
      find.text('No diagnostics data'),
      findsNothing,
      reason: 'the sessionless PSF tiles are exactly the data to analyze',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no quick-capture entry when there is nothing to diagnose',
      (tester) async {
    await pumpAppScreen(
      tester,
      const DiagnosticsScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _overrides(withQuickCaptureData: false),
    );
    await _drainAsyncFrames(tester);

    expect(find.text('Quick captures (no session)'), findsNothing);
    expect(find.text('Select an imaging session to analyze'), findsOneWidget);
  });
}
