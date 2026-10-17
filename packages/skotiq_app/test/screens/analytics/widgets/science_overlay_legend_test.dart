// Widget tests for the ScienceOverlayLegend dialog + inline strip.
//
// The legend is a pure UI helper (no providers, no streams). Tests verify
// that:
//   - known keys open a dialog with the expected headline and gradient,
//   - unknown keys silently no-op (graceful degradation, not an exception),
//   - `inlineFor` returns a renderable widget for quantitative overlays.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_overlay_legend.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _harness({required Widget child}) {
  return MaterialApp(
    theme: ThemeData(extensions: const [SkotiqColors.dark]),
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('show() opens a dialog for a known overlay key', (tester) async {
    await tester.pumpWidget(_harness(
      child: Builder(builder: (context) {
        return TextButton(
          onPressed: () => ScienceOverlayLegend.show(context, 'psf'),
          child: const Text('open'),
        );
      }),
    ));
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('PSF heatmap'), findsOneWidget);
    expect(find.textContaining('FWHM'), findsWidgets);
  });

  testWidgets('show() silently no-ops for an unknown key', (tester) async {
    await tester.pumpWidget(_harness(
      child: Builder(builder: (context) {
        return TextButton(
          onPressed: () =>
              ScienceOverlayLegend.show(context, 'definitely-not-a-key'),
          child: const Text('open'),
        );
      }),
    ));
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('inlineFor returns a renderable widget for clip_high',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: Builder(builder: (context) {
        return ScienceOverlayLegend.inlineFor(context, 'clip_high');
      }),
    ));
    await tester.pump();

    expect(find.textContaining('Safe'), findsOneWidget);
    expect(find.textContaining('Saturated'), findsOneWidget);
  });

  testWidgets(
      'inlineFor returns SizedBox.shrink for an overlay with no gradient',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: Builder(builder: (context) {
        return ScienceOverlayLegend.inlineFor(context, 'residuals');
      }),
    ));
    await tester.pump();

    expect(find.byType(SizedBox), findsWidgets,
        reason: 'A widget should render — preferring SizedBox.shrink over '
            'throwing for overlays without quantitative gradients.');
    expect(find.textContaining('Safe'), findsNothing);
  });
}
