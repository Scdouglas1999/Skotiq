// Every info banner is blue (`colors.info`) and keeps the red family for
// problems.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('an info banner paints in the info color', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: SkotiqBanner(title: 'Heads up')),
      ),
    );
    final colors = SkotiqColors.dark;
    expect(tester.widget<Icon>(find.byType(Icon)).color, colors.info);
    final box =
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.byType(Icon),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration?;
    expect(
      box?.color,
      colors.info.withValues(alpha: SkotiqTokens.opacityHairline),
    );
  });
}
