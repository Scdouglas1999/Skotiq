import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction, SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _showDialog(WidgetTester tester, Widget dialog) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => dialog),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders title, icon, body content', (tester) async {
    await _showDialog(
      tester,
      const SkotiqDialog(
        title: 'Settings',
        icon: LucideIcons.settings,
        child: Text('Body content goes here'),
      ),
    );

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Body content goes here'), findsOneWidget);
    expect(find.byIcon(LucideIcons.settings), findsOneWidget);
  });

  testWidgets('close button pops route by default', (tester) async {
    await _showDialog(
      tester,
      const SkotiqDialog(title: 'Settings', child: Text('Body')),
    );
    expect(find.byType(SkotiqDialog), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.byType(SkotiqDialog), findsNothing);
  });

  testWidgets('close button calls onClose when provided', (tester) async {
    var calls = 0;
    await _showDialog(
      tester,
      SkotiqDialog(
        title: 'Settings',
        onClose: () => calls++,
        child: const Text('Body'),
      ),
    );

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(calls, 1);
    // onClose owns lifecycle — dialog should still be visible.
    expect(find.byType(SkotiqDialog), findsOneWidget);
  });

  testWidgets('closeEnabled false blocks every user dismissal path', (
    tester,
  ) async {
    await _showDialog(
      tester,
      const SkotiqDialog(
        title: 'Saving',
        closeEnabled: false,
        child: Text('Writing changes'),
      ),
    );

    final closeButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, LucideIcons.x),
    );
    expect(closeButton.onPressed, isNull);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(SkotiqDialog), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SkotiqDialog), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SkotiqDialog), findsNothing);
  });

  testWidgets('actions slot renders provided widgets', (tester) async {
    await _showDialog(
      tester,
      SkotiqDialog(
        title: 'Confirm',
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.outline,
            onPressed: () {},
          ),
          SkotiqButton(label: 'OK', onPressed: () {}),
        ],
        child: const Text('Are you sure?'),
      ),
    );

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets('hideCloseButton hides the close icon', (tester) async {
    await _showDialog(
      tester,
      const SkotiqDialog(
        title: 'No close',
        showCloseButton: false,
        child: Text('Body'),
      ),
    );
    expect(find.byIcon(LucideIcons.x), findsNothing);
  });

  testWidgets('close button has accessible semantics', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await _showDialog(
        tester,
        const SkotiqDialog(
          title: 'A11y',
          closeButtonSemanticsLabel: 'Dismiss settings',
          child: Text('Body'),
        ),
      );

      // Locate the explicit Semantics wrapper we added around the close
      // IconButton — the tooltip and the wrapper both surface 'Dismiss
      // settings', but we want to assert the wrapper's button flag.
      final semantics = tester.getSemantics(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Dismiss settings',
        ),
      );
      expect(semantics.flagsCollection.isButton, isTrue);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('the close control publishes exactly one node, and it is named', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      var closed = 0;
      await _showDialog(
        tester,
        SkotiqDialog(
          title: 'A11y',
          onClose: () => closed++,
          child: const Text('Body'),
        ),
      );

      // Every button node the bridge is handed, with its name. The close
      // control used to publish two: the named one, and a nameless one nested
      // inside it that came from the IconButton's own annotation. Nodes merged
      // into a parent are skipped — those are folded into the parent before the
      // update leaves the framework, so no assistive tech ever sees them.
      final buttons = <String>[];
      void visit(SemanticsNode node) {
        final data = node.getSemanticsData();
        if (!node.isMergedIntoParent && data.flagsCollection.isButton) {
          buttons.add(data.label);
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
      expect(buttons, ['Close dialog']);

      // And the one node that is left is the one that closes: a reader
      // activating it must not be handed a node with no action on it.
      final node = tester.getSemantics(find.bySemanticsLabel('Close dialog'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(closed, 1);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('body is scrollable when content overflows', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _showDialog(
      tester,
      SkotiqDialog(
        title: 'Tall',
        height: 320,
        child: Column(
          children: List.generate(
            20,
            (i) => SizedBox(height: 40, child: Text('Row $i')),
          ),
        ),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
