import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/skotiq_bottom_navigation.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Pump the bar at [route] and return the labels of the selected slots.
///
/// Read from SEMANTICS rather than from the selected pill's decoration. The
/// pill is a sibling of its label now, not its ancestor, so walking the render
/// tree from the decoration finds no text — and `selected` on the semantics
/// node is the contract that actually matters here: it is what tells an
/// assistive-tech user which slot they are standing in.
Future<List<String>> _selectedLabels(
  WidgetTester tester,
  String route,
) async {
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        bottomNavigationBar: SkotiqBottomNavigation(
          currentRoute: route,
          onRouteSelected: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final selected = <String>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.flagsCollection.isSelected == Tristate.isTrue &&
        data.label.isNotEmpty) {
      selected.add(data.label);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  handle.dispose();
  return selected;
}

void main() {
  // The bar's selection is a statement about where the operator is. Exact route
  // matching left it blank on legitimate sub-routes (the image-ready deep link
  // /imaging/preview/:id renders the Imaging screen), so the phone showed a
  // screen with nothing in the bar claiming it.
  testWidgets('a sub-route lights the slot that hosts it', (tester) async {
    expect(await _selectedLabels(tester, '/imaging'), isNotEmpty);
    expect(
      await _selectedLabels(tester, '/imaging/preview/42'),
      await _selectedLabels(tester, '/imaging'),
    );
  });

  testWidgets('a route the More sheet owns lights More', (tester) async {
    // Settings has no slot of its own, but it IS in the More sheet (04 §3.3),
    // so More is where the operator actually is. Lighting nothing would leave
    // the bar silent on a screen it can reach.
    expect(await _selectedLabels(tester, '/settings'), ['More']);
    expect(await _selectedLabels(tester, '/settings/plate-solving'), ['More']);
    expect(await _selectedLabels(tester, '/flat-wizard'), ['More']);
  });

  testWidgets('a route nothing owns lights nothing', (tester) async {
    expect(await _selectedLabels(tester, '/unknown-route'), isEmpty);
    expect(await _selectedLabels(tester, '/polar-alignment'), isEmpty);
  });

  // The bar is the rail's phone-width replacement, so it owes assistive tech
  // the same three answers the rail's NavItem gives: this is a button, this is
  // the one you are standing in, and it is live. Measured on the running app at
  // 420x900 before the fix, all seven destinations came back from AT-SPI as
  // `panel` with states [focusable, showing, visible] — no role, no selected,
  // no enabled.
  testWidgets('every destination publishes role, selection and enabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          bottomNavigationBar: SkotiqBottomNavigation(
            currentRoute: '/imaging',
            onRouteSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Walked from the semantics tree, not from `getSemantics(find.text(...))`:
    // each slot's Semantics node EXCLUDES its Text child (otherwise the node
    // merges into "More\nMore" and a screen reader says it twice), so the
    // Text is no longer a node of its own to look up.
    final nodes = <SemanticsData>[];
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.isButton && data.label.isNotEmpty) {
        nodes.add(data);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
    if (root != null) visit(root);
    final labels = nodes.map((n) => n.label).toList();
    expect(labels, isNotEmpty);

    var selectedCount = 0;
    for (final data in nodes) {
      final label = data.label;
      final flags = data.flagsCollection;
      expect(
        flags.isButton,
        isTrue,
        reason: '"$label" publishes no button role',
      );
      expect(
        flags.isEnabled,
        Tristate.isTrue,
        reason: '"$label" does not announce itself as enabled',
      );
      expect(
        flags.isSelected,
        isNot(Tristate.none),
        reason: '"$label" publishes no selected state',
      );
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: '"$label" is not tappable through semantics',
      );
      if (flags.isSelected == Tristate.isTrue) selectedCount += 1;
    }

    // Exactly the Imaging slot is selected: a bar that marks none leaves a
    // screen-reader operator with no answer to "where am I", and one that
    // marks several is worse than none.
    expect(selectedCount, 1);

    handle.dispose();
  });

  testWidgets('bottom nav items meet minimum touch target', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          bottomNavigationBar: SkotiqBottomNavigation(
            currentRoute: '/dashboard',
            onRouteSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final inkWells = tester.widgetList<InkWell>(find.byType(InkWell));
    for (final inkWell in inkWells) {
      final context = tester.element(find.byWidget(inkWell));
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      expect(
        box.size.height,
        greaterThanOrEqualTo(SkotiqTokens.minTouchTarget - 1),
        reason:
            'Bottom nav tap target height below ${SkotiqTokens.minTouchTarget}pt',
      );
    }
  });
}
