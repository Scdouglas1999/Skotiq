// All-zero score weights are not a readability preference: AdaptiveSwapService
// .compose returns null at `weightTotal <= 0`, the driver pushes that null to
// the executor, and every swap decision becomes ConditionsUnknown — so the page
// must reject the all-zero config rather than describe it as a renormalisation.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/adaptive_conditions_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(
  WidgetTester tester,
  Map<String, double> weights,
) async {
  final database = mockDatabase();
  await database.settingsDao.setSettings({
    'adaptive_swap.score_weights': jsonEncode(weights),
  });
  addTearDown(database.close);
  return pumpAppScreen(
    tester,
    const SingleChildScrollView(child: AdaptiveConditionsSettings()),
    size: const Size(1000, 1600),
    database: database,
    settle: false,
  );
}

Future<void> _pumpWrites(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('zeroing the last non-zero weight is refused, not saved',
      (tester) async {
    final handle = await _pump(tester, const {
      'transparency': 0.4,
      'seeing': 0.0,
      'cloud': 0.0,
      'wind': 0.0,
    });
    await _pumpWrites(tester);

    final field =
        find.byKey(const ValueKey('adaptiveSwapTransparencyWeightInput'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);

    expect(find.byKey(const Key('adaptiveSwapWeightError')), findsOneWidget);
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .conditionsScoreWeights['transparency'],
      0.4,
      reason: 'the write that would switch adaptive swapping off must not land',
    );
    expect(
      await handle.database.settingsDao
          .getSetting('adaptive_swap.score_weights'),
      jsonEncode(const {
        'transparency': 0.4,
        'seeing': 0.0,
        'cloud': 0.0,
        'wind': 0.0,
      }),
    );
  });

  testWidgets('zeroing a weight that still leaves a non-zero total is allowed',
      (tester) async {
    final handle = await _pump(tester, const {
      'transparency': 0.4,
      'seeing': 0.25,
      'cloud': 0.25,
      'wind': 0.10,
    });
    await _pumpWrites(tester);

    final field =
        find.byKey(const ValueKey('adaptiveSwapTransparencyWeightInput'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);

    expect(find.byKey(const Key('adaptiveSwapWeightError')), findsNothing);
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .conditionsScoreWeights['transparency'],
      0.0,
    );
  });

  testWidgets('an already-zero total is described truthfully', (tester) async {
    // Reachable from an older DB, a remote host, or a hand-edited settings
    // row, so the callout still has to be honest about it.
    await _pump(tester, const {
      'transparency': 0.0,
      'seeing': 0.0,
      'cloud': 0.0,
      'wind': 0.0,
    });
    await _pumpWrites(tester);

    expect(
      find.textContaining('The composer renormalizes available axes'),
      findsNothing,
      reason: 'nothing is renormalized when compose() bails at total <= 0',
    );
    expect(
      find.textContaining('No conditions score can be computed'),
      findsOneWidget,
    );
    expect(
      find.textContaining('adaptive swapping will not run'),
      findsOneWidget,
    );
  });
}
