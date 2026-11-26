// On a phone, Tonight's plan line sits under the run pill beside three glyph
// buttons. It may take two lines there, and breaks only between its parts,
// so the time to dark before a run and the step and frame counts during one
// are never cut to an ellipsis.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../golden/surface_golden_harness.dart';
import 'night_screen_test_support.dart';

void main() {
  // Real fonts: the test font's square glyphs would wrap any line.
  setUpAll(SurfaceGoldenHarness.ensureCaptureFonts);

  for (final state in [NightScreenState.ready, NightScreenState.running]) {
    testWidgets('the ${state.name} plan line is whole at 360 dp', (
      tester,
    ) async {
      await pumpNightShell(
        tester,
        overrides: nightScreenOverrides(state),
        railCollapsed: true,
        size: const Size(360, 780),
      );
      expect(tester.takeException(), isNull);

      final line = find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().startsWith('M74 Plan'),
      );
      expect(line, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(line);
      expect(paragraph.didExceedMaxLines, isFalse);
      final text = paragraph.text.toPlainText();
      expect(
        text,
        contains(state == NightScreenState.ready ? 'dark in' : '44/60'),
      );
      await unmountNightShell(tester);
    });
  }
}
