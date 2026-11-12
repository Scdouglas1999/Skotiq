// Widget tests for ScienceSolveRateCard. Verifies that the card adapts to
// the four operating tiers (warm-up, excellent, struggling, broken) and that
// the "Configure plate solver" CTA only appears when help is actually
// useful.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_solve_rate_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as drift
    show DbCapturedImage;
import 'package:skotiq_ui/skotiq_ui.dart';

drift.DbCapturedImage _frame({required int id, required bool solved}) {
  final now = DateTime(2026, 1, 1);
  return drift.DbCapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 60,
    binX: 1,
    binY: 1,
    isPlateSolved: solved,
    capturedAt: now,
    createdAt: now,
    isAccepted: true,
  );
}

/// [failedIds] are the frames a solver ran on and could not solve; by
/// default every unsolved frame in [frames].
Widget _harness(List<DbCapturedImage> frames, {Set<int>? failedIds}) {
  final failed = failedIds ??
      {
        for (final f in frames)
          if (!f.isPlateSolved) f.id
      };
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
      plateSolveFailedFrameIdsProvider.overrideWith(
        (ref) => Stream.value(failed),
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

  testWidgets('warm-up state when no frames have been captured',
      (tester) async {
    await tester.pumpWidget(_harness(const []));
    await tester.pump();
    expect(find.text('Warming up'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Configure plate solver'), findsNothing);
  });

  testWidgets('excellent state with 90%+ solve rate', (tester) async {
    final frames = <DbCapturedImage>[
      for (var i = 0; i < 9; i++) _frame(id: i, solved: true),
      _frame(id: 9, solved: false),
    ];
    await tester.pumpWidget(_harness(frames));
    await tester.pump();
    expect(find.text('Excellent'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget);
    expect(find.text('9 of 10 solved'), findsOneWidget);
    expect(find.text('Configure plate solver'), findsNothing);
  });

  testWidgets('struggling state surfaces the configure CTA', (tester) async {
    final frames = <DbCapturedImage>[
      _frame(id: 1, solved: true),
      _frame(id: 2, solved: false),
      _frame(id: 3, solved: false),
      _frame(id: 4, solved: false),
      _frame(id: 5, solved: false),
    ];
    await tester.pumpWidget(_harness(frames));
    await tester.pump();
    expect(find.text('Struggling'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('Configure plate solver'), findsOneWidget);
  });

  testWidgets('broken state when nothing solved', (tester) async {
    final frames = <DbCapturedImage>[
      _frame(id: 1, solved: false),
      _frame(id: 2, solved: false),
      _frame(id: 3, solved: false),
    ];
    await tester.pumpWidget(_harness(frames));
    await tester.pump();
    expect(find.text('No solves yet'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('Configure plate solver'), findsOneWidget);
  });

  testWidgets('frames never sent to a solver are not failures', (tester) async {
    // Twenty snapshots before a solver was set up, then one solved frame.
    final frames = <DbCapturedImage>[
      for (var i = 0; i < 20; i++) _frame(id: i, solved: false),
      _frame(id: 20, solved: true),
    ];
    await tester.pumpWidget(_harness(frames, failedIds: const {}));
    await tester.pump();
    expect(find.text('Struggling'), findsNothing);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('1 of 1 solved · 20 not submitted'), findsOneWidget);
  });

  testWidgets('says so when no frame has been sent to a solver',
      (tester) async {
    final frames = <DbCapturedImage>[
      for (var i = 0; i < 5; i++) _frame(id: i, solved: false),
    ];
    await tester.pumpWidget(_harness(frames, failedIds: const {}));
    await tester.pump();
    expect(find.text('Not solving'), findsOneWidget);
    expect(find.text('no frames sent to a solver'), findsOneWidget);
    expect(find.text('No solves yet'), findsNothing);
  });
}
