// What the polar-alignment wizard offers an operator who has never opened its
// settings.
//
// Both numbers here are the ones that failed on the owner's rig: the dialog
// shipped a 30 s solve budget and the run sent that to the native side, where
// a full-resolution pole-region frame took 26.5 s to solve blind on a good
// night and was killed mid-solve on a bad one. The binning default is the
// cheaper half of the same fix — a binned frame solves in a quarter of the
// time — and it is only a real default if the panel is actually showing it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_app/screens/polar_alignment/widgets/polar_alignment_segmented_button.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

GoRouter _router() => GoRouter(
      initialLocation: '/polar-alignment',
      routes: [
        GoRoute(
          path: '/polar-alignment',
          builder: (_, __) => const PolarAlignmentScreen(),
        ),
      ],
    );

Future<void> _pumpWizard(WidgetTester tester) async {
  await pumpAppScreen(
    tester,
    MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: _router(),
    ),
    size: const Size(1400, 900),
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 200));
}

/// The settings sections start collapsed, and a collapsed [ExpansionTile] does
/// not build its children at all — so a section has to be opened before
/// anything can be asserted about what it shows. The setup checklist heads the
/// same column while idle, so the section is scrolled into view first.
Future<void> _openSettingsSection(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title));
  await tester.pump();
  await tester.tap(find.text(title));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('a fresh config solves at binning 2 on a 90 second budget', () {
    const config = PolarAlignmentConfig();
    expect(config.binning, 2);
    expect(config.solveTimeout, 90.0);
    expect(
      config.validate(),
      isEmpty,
      reason: 'the default the dialog ships must pass its own validator',
    );
  });

  test('every preset budgets enough for a solve to finish', () {
    for (final config in [
      const PolarAlignmentConfig(),
      PolarAlignmentConfig.quickStart(),
      PolarAlignmentConfig.highPrecision(),
    ]) {
      expect(
        config.solveTimeout,
        greaterThanOrEqualTo(60.0),
        reason: 'a blind pole-region solve measured 26.5s on the rig; the '
            'budget covers a hinted attempt and that fallback behind it',
      );
      expect(config.validate(), isEmpty);
    }
  });

  testWidgets('the wizard opens on binning 2 and explains why', (tester) async {
    await _pumpWizard(tester);
    await _openSettingsSection(tester, 'Common');

    final binning = tester.widget<PolarAlignmentSegmentedButton<int>>(
      find.byType(PolarAlignmentSegmentedButton<int>).first,
    );
    expect(binning.selected, {2});

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains(
              'Binning 2 solves in a quarter of the time; alignment accuracy '
              'is unaffected.',
            ),
      ),
      findsOneWidget,
      reason: 'the operator is being asked to give up resolution; the panel '
          'has to say what it buys and what it costs',
    );
  });

  testWidgets('the wizard opens on a 90 second solve budget', (tester) async {
    await _pumpWizard(tester);
    await _openSettingsSection(tester, 'Advanced');

    // The slider's own value is the setting; the "90s" label beside it is what
    // the operator reads.
    final slider = tester.widgetList<Slider>(find.byType(Slider)).firstWhere(
          (s) => s.min == 10 && s.max == 120,
        );
    expect(slider.value, 90.0);
    expect(find.text('90s'), findsOneWidget);
  });
}
