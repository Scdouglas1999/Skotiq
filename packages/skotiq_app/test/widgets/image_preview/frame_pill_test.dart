import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/image_preview/frame_overlay_controls.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  // Mobile rework SM1 / night test 2026-11-26: on a phone the exposing pill
  // read "#77 exposing Dark 55 s 2…", cutting the countdown.
  testWidgets('a narrow pill shortens its words, not its value',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              // The test font draws square glyphs: the value alone is ~145 px.
              width: 260,
              child: Row(
                children: [
                  Flexible(
                    child: FramePill(
                      text: FramePillText(
                        title: '#77 exposing',
                        time: 'Dark 55 s',
                        mono: '21 s left',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final value = find.textContaining('21 s left', findRichText: true);
    expect(value, findsOneWidget);
    final rich = tester.widget<RichText>(value);
    expect(rich.text.toPlainText().trim(), '21 s left');
    expect(
      tester.renderObject<RenderParagraph>(value).didExceedMaxLines,
      isFalse,
    );
    final words = find.textContaining('#77 exposing', findRichText: true);
    expect(
      tester.renderObject<RenderParagraph>(words).didExceedMaxLines,
      isTrue,
      reason: 'the words give way to the value',
    );
  });

  testWidgets('a pill narrower than its value shortens it, never overflows',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 90,
              child: Row(
                children: [
                  Flexible(
                    child: FramePill(
                      text: FramePillText(
                        title: '#77 exposing',
                        time: 'Dark 55 s',
                        mono: '21 s left',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
