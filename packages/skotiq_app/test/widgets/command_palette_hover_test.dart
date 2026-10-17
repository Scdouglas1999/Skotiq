// The pointer must not steal the palette's Enter target.
//
// Live: Ctrl+K, type "weath", Enter — and the palette opened "Weather safety"
// rather than the first result, "Weather". The cursor happened to be resting
// over the fifth row, and every row moved the selection to itself on
// `onEnter`, so whatever the pointer was over became what Enter would run.
// 04 §7 gives the selection to the arrow keys; hover paints a hover tone and
// nothing else.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/command_palette/command_palette.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The palette's result rows, in the order they are painted.
  List<SemanticsNode> resultRows(WidgetTester tester) {
    final nodes = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (node.getSemanticsData().hasFlag(SemanticsFlag.hasSelectedState)) {
        nodes.add(node);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return nodes;
  }

  /// Which row carries the keyboard selection — the row Enter will run.
  int selectedIndex(WidgetTester tester) {
    final rows = resultRows(tester);
    return rows.indexWhere(
      (n) => n.getSemanticsData().hasFlag(SemanticsFlag.isSelected),
    );
  }

  Future<void> hoverRow(WidgetTester tester, int index) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final target = tester.getCenter(find.byType(GestureDetector).at(index));
    await tester.sendEventToBinding(pointer.hover(target));
    await tester.pump();
  }

  testWidgets('the pointer paints a hover tone and moves nothing', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(tester, const CommandPalette());

    expect(
      selectedIndex(tester),
      0,
      reason: 'the palette opens with the first result armed',
    );

    await hoverRow(tester, 3);

    expect(
      selectedIndex(tester),
      0,
      reason: 'the row under the cursor became the Enter target, so typing '
          '"weath" and pressing Enter opened whatever the pointer was over',
    );
    handle.dispose();
  });

  testWidgets('the arrow keys still own the selection while hovering', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(tester, const CommandPalette());

    await hoverRow(tester, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(
      selectedIndex(tester),
      1,
      reason: 'Down moves one row from the first result, whatever the pointer '
          'is doing',
    );
    handle.dispose();
  });

  testWidgets('a selected row and a hovered row do not look the same', (
    tester,
  ) async {
    await pumpAppScreen(tester, const CommandPalette());

    Color? fillOf(int index) {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(GestureDetector).at(index),
              matching: find.byType(Container),
            )
            .first,
      );
      return (container.decoration! as BoxDecoration).color;
    }

    const colors = SkotiqColors.dark;
    // The selected row wears the tint every selected thing in this language
    // wears, so the operator can see what Enter will run even while the
    // pointer is somewhere else.
    expect(
      fillOf(0),
      colors.primary.withValues(alpha: SkotiqTokens.opacityAccentTint),
    );

    await hoverRow(tester, 3);
    expect(fillOf(3), colors.surfaceHover);
    expect(
      fillOf(0),
      colors.primary.withValues(alpha: SkotiqTokens.opacityAccentTint),
      reason: 'hovering elsewhere must not un-arm the selection',
    );
  });
}
