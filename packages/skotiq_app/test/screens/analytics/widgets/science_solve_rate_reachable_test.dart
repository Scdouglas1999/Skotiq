// The Plate solve health card must tell a reachable-but-failing solver apart
// from a missing one. With a solver installed, configured and launched per frame
// — `Running ASTAP: ".../astap_cli" -f …` followed by `No solution found! :(`
// and `ASTAP exited with non-zero status 1` — a card saying "most science
// products will stay empty until a solver is reachable" sends the user to
// reinstall their solver instead of checking pointing and scale.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_solve_rate_card.dart';
import 'package:skotiq_core/skotiq_core.dart' hide CapturedImage;
import 'package:skotiq_core/src/database/database.dart' as drift
    show CapturedImage;
import 'package:skotiq_ui/skotiq_ui.dart';

drift.CapturedImage _unsolvedLight(int id) {
  final now = DateTime(2026, 8, 13, 9, id);
  return drift.CapturedImage(
    id: id,
    filePath: '/captures/l$id.fits',
    fileName: 'l$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 3,
    binX: 1,
    binY: 1,
    isPlateSolved: false,
    capturedAt: now,
    createdAt: now,
    isAccepted: true,
  );
}

Widget _harness(
  List<DbCapturedImage> frames, {
  PlateSolverDetection? detection,
  Future<PlateSolverDetection>? pending,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: ScienceSolveRateCard(
            colors: SkotiqColors.dark,
            lightFrames: frames,
          ),
        ),
      ),
      GoRoute(
        path: '/settings/plate-solving',
        builder: (_, __) => const Scaffold(body: Text('PlateSolverSettings')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      plateSolverDetectionProvider.overrideWith(
        (ref) => pending ?? Future.value(detection!),
      ),
    ],
    child: MaterialApp.router(
      theme: ThemeData(extensions: const [SkotiqColors.dark]),
      routerConfig: router,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zeroSolves = [for (var i = 1; i <= 32; i++) _unsolvedLight(i)];

  testWidgets('a reachable solver that fails is not blamed on reachability',
      (tester) async {
    await tester.pumpWidget(_harness(
      zeroSolves,
      detection: const PlateSolverDetection(
        astapPath: '/usr/bin/astap_cli',
        catalogPath: '/usr/share/astap',
        catalogName: 'V17',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No solves yet'), findsOneWidget);
    expect(
      find.textContaining('until a solver is reachable'),
      findsNothing,
      reason: 'ASTAP is installed with a catalog — it is running and failing',
    );
    expect(find.textContaining('is installed'), findsOneWidget);
    expect(find.textContaining('focal length'), findsOneWidget);
  });

  testWidgets('with no solver installed the card still says so',
      (tester) async {
    await tester.pumpWidget(_harness(
      zeroSolves,
      detection: const PlateSolverDetection(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No solves yet'), findsOneWidget);
    expect(find.textContaining('No plate solver is installed'), findsOneWidget);
    expect(find.text('Configure plate solver'), findsOneWidget);
  });

  testWidgets('before detection answers, the card claims neither',
      (tester) async {
    final pending = Completer<PlateSolverDetection>();
    addTearDown(() => pending.complete(const PlateSolverDetection()));

    await tester.pumpWidget(_harness(zeroSolves, pending: pending.future));
    await tester.pump();

    expect(find.textContaining('until a solver is reachable'), findsNothing);
    expect(find.textContaining('No plate solver is installed'), findsNothing);
    expect(find.textContaining('is installed'), findsNothing);
    expect(
      find.textContaining('whether a solver is configured'),
      findsOneWidget,
    );
  });
}
