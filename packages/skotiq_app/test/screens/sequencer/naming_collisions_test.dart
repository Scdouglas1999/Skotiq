// Two different things were both called "Save", and two different surfaces
// were both called "Templates".
//
//   * The toolbar floppy wrote a .skeq file through the OS chooser; the
//     Sequences tab's "Save Current" saves into the app library. A new user
//     cannot tell which one persists their work.
//   * The Builder's left panel is the "Snippets" tab, its import tooltip says
//     "Import snippet from file...", it stores TemplateSnippets - and it
//     titled itself "Templates", which is also the name of a top-level tab
//     holding whole saved sequences.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/snippet_palette.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

List<Override> _overrides({SequenceFileService? fileService}) {
  final editor = CurrentSequenceNotifier();
  final root = InstructionSetNode(name: 'Root');
  // ignore: invalid_use_of_protected_member
  editor.state = Sequence.create(
    name: 'Tonight',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
  return [
    currentSequenceProvider.overrideWith((_) => editor),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
    allSnippetsProvider.overrideWithValue(const []),
    if (fileService != null)
      sequenceFileServiceProvider.overrideWithValue(fileService),
  ];
}

/// Fails the write so the toolbar's failure copy is observable.
class _FailingFileService extends SequenceFileService {
  @override
  Future<String?> exportSequence(
    Sequence sequence, {
    bool forceExport = false,
  }) async {
    throw StateError('no space left on device');
  }
}

/// The canvas bar's export-to-file button.
Finder _exportButton() => find.byWidgetPredicate(
      (widget) =>
          widget is SkotiqIconButton &&
          widget.tooltip.startsWith('Export sequence file'),
      description: 'the canvas bar\'s export button',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the toolbar file action does not call itself Save',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      size: const Size(1600, 400),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    // The action is the canvas bar's save button; its tooltip carries the
    // name. `find.byTooltip` no longer reaches it — SkotiqIconButton
    // renders SkotiqTooltip and publishes the tooltip as its semantics
    // label — so match the widget.
    expect(_exportButton(), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SkotiqIconButton &&
            widget.tooltip.toLowerCase().contains('save sequence'),
      ),
      findsNothing,
    );
    // And there is exactly ONE of it: the duplicate menu entry that spelled
    // the same action differently is gone.
    await openCanvasBarMenu(tester);
    expect(canvasBarAction('Export sequence file…'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
  });

  // Renaming only the button leaves the collision alive on the failure path:
  // press "Export Sequence File…", get "Failed to save sequence" and you are
  // back to wondering whether your library save just failed.
  testWidgets('the file action reports failure as an export, not a save',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      size: const Size(1600, 400),
      extraOverrides: _overrides(fileService: _FailingFileService()),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(_exportButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining('Failed to export sequence file'),
      findsOneWidget,
    );
    expect(find.textContaining('Failed to save sequence'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the snippets panel calls itself Snippets', (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SnippetPalette(colors: SkotiqColors.of(context)),
      ),
      size: const Size(400, 800),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Snippets'), findsWidgets);
    expect(find.text('Templates'), findsNothing);
    expect(
      find.widgetWithText(TextField, 'Search templates...'),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 1));
  });
}
