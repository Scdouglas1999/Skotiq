// The annotation label dialog was the one dialog on the Imaging screen built
// on a stock Material AlertDialog: a hardcoded #1A1A2E navy surface with
// Material's greenAccent (#00E676) on the focused underline and the confirm
// action — the brightest thing on a dark-adapted display, and the only primary
// action in the app that is not the Skotiq accent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/custom_annotation_drawing.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _materialGreenAccent = Color(0xFF00E676);
const _strayNavy = Color(0xFF1A1A2E);

void main() {
  testWidgets('drawing a circle opens a Skotiq-styled label dialog',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    // Pick the circle tool, exactly as the floating annotation toolbar does.
    container.read(customAnnotationToolProvider.notifier).state =
        CustomAnnotationType.circle;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: CustomAnnotationDrawingLayer(
              zoomLevel: 1.0,
              imageOffset: Offset.zero,
              imageSize: Size(1000, 800),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Drag out a circle on the image; releasing raises the label dialog.
    await tester.dragFrom(const Offset(400, 400), const Offset(120, 120));
    await tester.pumpAndSettle();

    expect(find.text('Circle Label'), findsOneWidget);
    expect(
      find.byType(SkotiqDialog),
      findsOneWidget,
      reason: 'the annotation flow must not leave the design system',
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SkotiqTextField), findsOneWidget);

    // The confirm action is a Skotiq primary button, not a green TextButton.
    final add = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Add'),
    );
    expect(add.variant, ButtonVariant.primary);

    // Nothing in the dialog paints Material's greenAccent or the stray navy.
    final offenders = <String>[];
    for (final element in find.byType(SkotiqDialog).evaluate()) {
      void visit(Element e) {
        final widget = e.widget;
        if (widget is Text) {
          final color = widget.style?.color;
          if (color == _materialGreenAccent) {
            offenders.add('Text ${widget.data}');
          }
        }
        if (widget is Container) {
          final decoration = widget.decoration;
          if (decoration is BoxDecoration && decoration.color == _strayNavy) {
            offenders.add('Container #1A1A2E');
          }
          if (widget.color == _strayNavy) offenders.add('Container #1A1A2E');
        }
        e.visitChildren(visit);
      }

      element.visitChildren(visit);
    }
    expect(offenders, isEmpty, reason: 'off-palette colours: $offenders');
  });
}
