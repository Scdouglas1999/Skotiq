// The window chrome's own controls publish an enabled state.
//
// `Semantics(button: true, …)` with no `enabled:` field resolves NO enabled
// state, and the AT-SPI bridge publishes ENABLED only for a node that resolves
// one — so Orca reads a working control as unavailable. The title bar shipped
// that on FIVE controls at once: the profile shortcut, the Settings gear, and
// minimize / maximize / close. Unlike the Darkroom instance of the same class,
// these are on every screen in the app.
//
// Driven against the rendered semantics tree rather than the source, because
// the source scan in `semantics_enabled_guard_test.dart` proves the field is
// written and this proves the node the operator's screen reader walks actually
// resolves it.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/window_chrome.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Every node in the tree under [root] that carries the button role.
List<SemanticsNode> _buttons(SemanticsNode root) {
  final found = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    if (node.hasFlag(SemanticsFlag.isButton)) found.add(node);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every window-control node resolves an enabled state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: WindowControls(colors: SkotiqColors.dark),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final nodes = _buttons(
        tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    final labelled = {
      for (final node in nodes)
        if (node.label.isNotEmpty) node.label: node,
    };

    for (final label in [
      'Minimize window',
      'Maximize window',
      'Close window',
    ]) {
      final node = labelled[label];
      expect(node, isNotNull, reason: '$label publishes no button node');
      // hasEnabledState is the flag the bridge reads BEFORE isEnabled: without
      // it the control resolves no state at all and reads as unavailable, which
      // is what all three of these did.
      expect(
        node!.hasFlag(SemanticsFlag.hasEnabledState),
        isTrue,
        reason: '$label resolves no enabled state',
      );
      expect(
        node.hasFlag(SemanticsFlag.isEnabled),
        isTrue,
        reason: '$label is live and must say so',
      );
    }
    // Disposed inside the body, not from a tear-down: the framework verifies
    // no handle is live at the END of the test, which runs before tear-downs.
    handle.dispose();
  });
}
