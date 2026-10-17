// Helper text under a form field must WRAP, not ellipsise.
//
// Flutter's InputDecoration.helperMaxLines defaults to null, which means a
// helper wider than the field is truncated with an ellipsis. In the sequencer
// properties panel (260-440 px wide) that cut the Live Stacking helpers in
// half - "Broadcast only keeps memory clean; Recor..." - removing exactly the
// clause that names the alternative the operator is choosing between.
//
// The wrap is set in the shared theme (SkotiqTheme inputDecorationTheme), so
// this asserts on the rendered helper Text, which is what the operator reads.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/live_stacking_properties.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

const _modeHelper =
    'Broadcast only keeps memory clean; Record also writes JPEG '
    'snapshots to disk.';
const _methodHelper =
    'Average is fastest; Median+Rej and Sigma reject outliers.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Live Stacking helper sentences wrap instead of ellipsising',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: LiveStackingProperties(
              colors: SkotiqColors.of(context),
              node: LiveStackingNode(),
            ),
          ),
        ),
      ),
      size: const Size(460, 900),
      settle: false,
    );
    await tester.pump();

    for (final helper in [_modeHelper, _methodHelper]) {
      final text = tester.widget<Text>(find.text(helper));
      // A single line is what produced "…; Recor…" in the shipped build.
      expect(
        text.maxLines,
        isNotNull,
        reason: 'helper "$helper" has no maxLines, so it ellipsises',
      );
      expect(text.maxLines, greaterThan(1));
    }
  });

  testWidgets('the whole helper sentence is laid out, not clipped',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: LiveStackingProperties(
              colors: SkotiqColors.of(context),
              node: LiveStackingNode(),
            ),
          ),
        ),
      ),
      size: const Size(460, 900),
      settle: false,
    );
    await tester.pump();

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text(_modeHelper),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    // Two-plus lines at 360 px wide: proof it actually wrapped.
    expect(paragraph.size.height, greaterThan(paragraph.preferredLineHeight));
  });
}
