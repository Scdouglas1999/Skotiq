import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_app/screens/stack_result/recent_stacks_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

StackAndShareResult _stack(int id, String target, {String? filter = 'Ha'}) =>
    StackAndShareResult(
      id: id,
      targetName: target,
      width: 100,
      height: 80,
      framesStacked: 24,
      framesAttempted: 25,
      integrationSecs: 7200,
      avgAlignmentResidual: 0.3,
      filter: filter,
      createdAt: DateTime(2026, 11, 10, 23, 30),
    );

Future<GoRouter> _pumpPanel(
  WidgetTester tester, {
  required Future<List<StackAndShareResult>> Function() load,
  bool linked = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: SingleChildScrollView(child: RecentStacksPanel()),
        ),
      ),
      GoRoute(
        path: '/stack-result',
        builder: (context, state) =>
            Text('result ${state.uri.queryParameters['id']}'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recentStackedResultsProvider.overrideWith((ref) => load()),
        isRemoteModeProvider.overrideWithValue(linked),
        stackResultThumbnailPathProvider.overrideWith((ref, id) async => null),
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  return router;
}

void main() {
  testWidgets('shows that it is loading', (tester) async {
    final pending = Completer<List<StackAndShareResult>>();
    await _pumpPanel(tester, load: () => pending.future);
    await tester.pump();
    expect(find.text('Loading recent stacks…'), findsOneWidget);
    pending.complete(const []);
    await tester.pump();
  });

  testWidgets('a rig that has never stacked says how to make one',
      (tester) async {
    await _pumpPanel(tester, load: () async => const []);
    await tester.pump();
    expect(find.text('No stacks yet'), findsOneWidget);
    expect(find.textContaining('Run Stack & Share on a finished session'),
        findsOneWidget);
  });

  testWidgets('a linked client points at the imaging host', (tester) async {
    await _pumpPanel(tester, load: () async => const [], linked: true);
    await tester.pump();
    expect(find.textContaining('on the imaging host'), findsOneWidget);
  });

  testWidgets('a failed load explains itself and retries', (tester) async {
    var attempts = 0;
    await _pumpPanel(
      tester,
      load: () async {
        attempts++;
        if (attempts == 1) throw StateError('database is locked');
        return [_stack(1, 'M31')];
      },
    );
    await tester.pump();
    expect(find.text('Could not load recent stacks'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text('M31'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets(
      'each stack shows target, filter, frames, exposure and date, and opens '
      'its result', (tester) async {
    final router = await _pumpPanel(
      tester,
      load: () async => [_stack(7, 'NGC 7380'), _stack(6, 'M81', filter: null)],
    );
    await tester.pump();

    expect(find.text('NGC 7380'), findsOneWidget);
    expect(find.text('Ha · 24 frames · 2h'), findsOneWidget);
    expect(find.text('24 frames · 2h'), findsOneWidget);
    expect(find.text('Nov 10, 2026'), findsNWidgets(2));

    await tester.tap(find.text('NGC 7380'));
    await tester.pumpAndSettle();
    expect(router.state.uri.toString(), '/stack-result?id=7');
    expect(find.text('result 7'), findsOneWidget);
  });

  testWidgets('long histories fold behind Show more', (tester) async {
    await _pumpPanel(
      tester,
      load: () async => [for (var i = 1; i <= 7; i++) _stack(i, 'Target $i')],
    );
    await tester.pump();
    expect(find.text('Target 5'), findsOneWidget);
    expect(find.text('Target 6'), findsNothing);
    await tester.tap(find.text('Show 2 more'));
    await tester.pump();
    expect(find.text('Target 7'), findsOneWidget);
  });

  testWidgets('the Live stack panel lists recent stacks', (tester) async {
    await pumpAppScreen(
      tester,
      const StackingPanel(colors: SkotiqColors.dark),
      size: const Size(420, 2400),
      settle: false,
      extraOverrides: [
        recentStackedResultsProvider.overrideWith(
          (ref) async => [_stack(3, 'IC 1396')],
        ),
        stackResultThumbnailPathProvider.overrideWith((ref, id) async => null),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('RECENT STACKS'), findsOneWidget);
    expect(find.text('IC 1396'), findsOneWidget);
  });
}
