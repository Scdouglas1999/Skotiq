// Closing the saved-frame viewer must not hand focus back to a text field the
// page had before: on a phone that reopens the keyboard over the screen.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/saved_frame/saved_frame_viewer.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('closing the viewer leaves no text field focused', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    late BuildContext pageContext;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          frameFileDecoderProvider.overrideWithValue(
            (path) async => bridge.FitsReadResult(
              width: 4,
              height: 3,
              bitpix: 16,
              displayData: Uint8List(4 * 3 * 4),
              histogram: Uint32List(256),
              stats: const bridge.ImageStatsResult(
                min: 0,
                max: 1,
                mean: 0,
                median: 0,
                stdDev: 0,
                starCount: 0,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                pageContext = context;
                return TextField(focusNode: field);
              },
            ),
          ),
        ),
      ),
    );
    field.requestFocus();
    await tester.pump();
    expect(field.hasFocus, isTrue);

    final open = SavedFrameViewer.show(
      pageContext,
      frames: [
        SavedFrameEntry(
          frame: SavedFrameRef(
            imageId: 1,
            hostPath: '/tmp/frame_1.fits',
            capturedAt: DateTime.utc(2026, 11, 27, 2),
          ),
          title: '#1 · L 30 s',
        ),
      ],
      initialIndex: 0,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SavedFrameViewer), findsOneWidget);

    Navigator.of(pageContext, rootNavigator: true).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await open;

    expect(field.hasFocus, isFalse);
  });
}
