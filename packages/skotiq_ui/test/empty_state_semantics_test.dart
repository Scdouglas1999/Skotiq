import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// An empty state with ONE action used to swallow the screen it filled.
///
/// A screen with a keyboard shortcut publishes one focusable node over
/// everything on it, and every unbounded fragment underneath merges into that
/// node. An [EmptyState] is an icon, a title, a paragraph and one button, so
/// the button's tap and role landed on the same node as all the words and the
/// screen reached AT-SPI as a single control named for its own prose. Measured
/// on the running Darkroom: its "Nothing to open" state was ONE ~300-character
/// button covering the whole screen, with no node named "Back to session
/// review" for an exact-name lookup to find. States with two or more actions
/// escaped it only because two taps cannot merge into one node, which is why
/// the same screen's start offer read correctly.
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(body: child),
  );

  /// Every node the platform is actually sent.
  ///
  /// A node merged into its parent is dropped from the update, so it is not
  /// what a screen reader walks — the ancestor's merged data is.
  List<SemanticsData> published(WidgetTester tester) {
    final root =
        tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
    final nodes = <SemanticsData>[];
    void visit(SemanticsNode node) {
      if (node.isMergedIntoParent) return;
      nodes.add(node.getSemanticsData());
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    return nodes;
  }

  /// A screen shaped the way the Darkroom is: a header, a body, and a
  /// focusable ancestor over both.
  ///
  /// The ancestor is what makes the collapse reachable, and every screen with a
  /// keyboard shortcut has one: `CallbackShortcuts` builds a `Focus`, and a
  /// `Focus` publishes `focusable` unless it is told not to, which is one
  /// annotated node covering the whole screen. Every descendant fragment that
  /// is not bounded merges into it — the header's words, the empty state's
  /// words, and the tap and role of the one control among them.
  Widget screen(Widget emptyState) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    child: Column(
      children: [
        const Text('Darkroom'),
        const Text('Nothing to open'),
        Expanded(child: emptyState),
      ],
    ),
  );

  testWidgets('the action keeps its own node and the words stay text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        screen(
          EmptyState(
            icon: LucideIcons.imageOff,
            title: 'Nothing to open in the Darkroom',
            body:
                'Recipe 4242 no longer has a row. Deleting a branch removes '
                'the recipe and nothing else.',
            action: SkotiqButton(
              label: 'Back to session review',
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    final nodes = published(tester);
    final buttons = nodes
        .where((data) => data.hasFlag(SemanticsFlag.isButton))
        .toList();
    expect(buttons, hasLength(1));
    expect(buttons.single.label, contains('Back to session review'));
    expect(
      buttons.single.label,
      isNot(contains('no longer has a row')),
      reason: 'the reason the screen gives is not the control\'s name',
    );
    expect(buttons.single.label, isNot(contains('Darkroom')));

    // The screen's own words are still readable — as text, on nodes with no
    // role, rather than only as part of a control's name.
    final words = nodes
        .where(
          (data) =>
              data.label.contains('Nothing to open in the Darkroom') ||
              data.label.contains('no longer has a row'),
        )
        .toList();
    expect(words, isNotEmpty);
    for (final data in words) {
      expect(data.hasFlag(SemanticsFlag.isButton), isFalse);
    }

    // And the control's node covers the control, not the screen: an activation
    // used to land on a node whose extents were everything.
    expect(
      tester.getSemantics(find.byType(SkotiqButton)).rect.size,
      tester.getSize(find.byType(SkotiqButton)),
    );
    handle.dispose();
  });

  testWidgets('the compact variant holds the same boundary', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        screen(
          EmptyState.compact(
            icon: LucideIcons.imageOff,
            title: 'This side could not be opened',
            body: 'The master this branch was written over is not on disk.',
            action: SkotiqButton(label: 'Reload', onPressed: () {}),
          ),
        ),
      ),
    );

    final buttons = published(
      tester,
    ).where((data) => data.hasFlag(SemanticsFlag.isButton)).toList();
    expect(buttons, hasLength(1));
    expect(buttons.single.label, contains('Reload'));
    expect(buttons.single.label, isNot(contains('could not be opened')));
    handle.dispose();
  });

  testWidgets('an empty state with no action publishes no control', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        screen(
          const EmptyState(
            icon: LucideIcons.image,
            title: 'Nothing rendered yet',
            body: 'The recipe has not been rendered over this master.',
          ),
        ),
      ),
    );

    expect(
      published(tester).where((d) => d.hasFlag(SemanticsFlag.isButton)),
      isEmpty,
    );
    handle.dispose();
  });
}
