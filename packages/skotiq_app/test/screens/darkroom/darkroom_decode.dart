import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/edit/darkroom_editor.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Let every Darkroom preview surface finish decoding the pixels it holds.
///
/// `decodeImageFromPixels` answers from the engine, which the fake clock inside
/// `testWidgets` never reaches, so real time has to pass. How much depends on
/// the machine's load, so this waits for the surfaces themselves: none may
/// still show its first-frame spinner or its "New frame…" tag. The two pumps
/// after that let the post-frame fit write the transform.
Future<void> awaitDecodedFrames(WidgetTester tester) async {
  bool decoding() {
    final surfaces = find.byKey(kDarkroomPreviewSurfaceKey);
    return find
            .descendant(of: surfaces, matching: find.byType(SkotiqMark))
            .evaluate()
            .isNotEmpty ||
        find
            .descendant(of: surfaces, matching: find.text('New frame…'))
            .evaluate()
            .isNotEmpty;
  }

  for (var i = 0; i < 1000 && decoding(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pump();
  await tester.pump();
}
