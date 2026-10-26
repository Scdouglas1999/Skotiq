import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  for (final checked in [
    <int>[],
    [10]
  ]) {
    testWidgets(
        'reports unvalidated subtraction with ${checked.length} checked tiles',
        (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final coverage = FirstLightCoverage.fromBridgeJson({
        'tilesChecked': checked,
        'tilesUnnormalized': [11, 12],
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          firstLightCoverageProvider.overrideWith((ref) => coverage),
          firstLightCandidatesProvider.overrideWith((ref) => Stream.value([])),
          recentNarratorFeedProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: FirstLightView()),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('subtraction could not be validated'),
          findsOneWidget);
      expect(
          find.textContaining('Atlas not deep enough here yet'), findsNothing);
      expect(
          find.textContaining(
              '${checked.length} of ${checked.length + 2} covered tiles'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
