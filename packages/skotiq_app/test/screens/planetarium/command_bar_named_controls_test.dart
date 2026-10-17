// Every button in the planetarium command bar announces a name, and no Material
// `Tooltip` is mounted inside it.
//
// A `PopupMenuButton` carries no name of its own, so the projection cycler and
// Tools dump as bare `button: ` nodes between
// `button: Equatorial view - switch to Alt/Az` and `button: Layers` — naming
// `CommandBarIconButton` from its tooltip does not reach them.
//
// The projection one also leaks: hovering it publishes
// `panel: Projection: Stereographic` under the bare button, and that node stays
// in the tree for the rest of the session while the command bar looks clean on
// screen. That node is Material's own `Tooltip`, which the fix in
// `skotiq_tooltip.dart` cannot reach unless the control uses
// `SkotiqTooltip`.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/redesign/command_bar.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  testWidgets('every command-bar button announces a name', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      PlanetariumCommandBar(
        compact: false,
        layersOpen: false,
        panelOpen: false,
        showFov: false,
        onToggleLayers: () {},
        onTogglePanel: () {},
        onOpenSearch: () {},
        onToggleFov: () {},
        onResetView: () {},
        onExportChart: () {},
      ),
      size: const Size(1400, 200),
      settle: false,
    );
    await tester.pump();

    final labels = <String>[];
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasFlag(SemanticsFlag.isButton)) {
        labels.add(data.label);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    // ignore: deprecated_member_use
    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);

    expect(labels, isNotEmpty, reason: 'the bar is made of buttons');
    expect(
      labels.where((label) => label.trim().isEmpty).length,
      0,
      reason: 'a bare `button: ` cannot be identified by anyone using the '
          'keyboard or a screen reader — found ${labels.length} buttons: '
          '$labels',
    );
    expect(
      labels.any((label) => label.startsWith('Projection: ')),
      isTrue,
      reason: 'the projection cycler names the projection it is on',
    );
    expect(
      labels.any((label) => label.trim() == 'Tools'),
      isTrue,
      reason: 'the Tools overflow names itself',
    );

    handle.dispose();
  });

  testWidgets('the command bar mounts no Material tooltip', (tester) async {
    // The D-2 leak's owner: a Material `Tooltip` publishes its message as a
    // semantics node of its own, and the live tree kept that node after the
    // pointer had left. Every message in this bar belongs to `SkotiqTooltip`
    // (which carries it on the trigger) instead.
    await pumpAppScreen(
      tester,
      PlanetariumCommandBar(
        compact: false,
        layersOpen: false,
        panelOpen: false,
        showFov: false,
        onToggleLayers: () {},
        onTogglePanel: () {},
        onOpenSearch: () {},
        onToggleFov: () {},
        onResetView: () {},
        onExportChart: () {},
      ),
      size: const Size(1400, 200),
      settle: false,
    );
    await tester.pump();

    // Material's `Tooltip` builds its child untouched when the message is
    // empty — no overlay, and no `tooltip` semantics node to strand. A
    // NON-empty one is the leak.
    final messages = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .where((m) => m.isNotEmpty)
        .toList();
    expect(messages, isEmpty);
  });
}
