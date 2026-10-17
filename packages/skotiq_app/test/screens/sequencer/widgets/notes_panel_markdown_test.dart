// Verify that note bodies in TargetNotesSection render
// markdown via flutter_markdown's MarkdownBody widget (instead of a
// plain Text). We don't try to grok the rendered glyphs (that's
// flutter_markdown's own responsibility); we just confirm that:
//
//   * MarkdownBody is present in the widget tree when a note has a
//     non-empty body, and
//   * the plain `Text(note.body, ...)` from the prior implementation
//     is no longer there for the body content.
//
// The actual styling — bold / italics / code fences — is exercised
// indirectly by the design-token styleSheet plumbing in
// `_noteBodyMarkdownStyle`; flutter_markdown's own test suite covers
// the parsing surface so we don't duplicate that here.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/notes_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpHost(
  WidgetTester tester, {
  required Widget child,
  required db.SkotiqDatabase database,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) => database),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.SkotiqDatabase database;

  setUp(() {
    database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('note bodies render via MarkdownBody, not raw Text',
      (tester) async {
    final service = NotesService(database);
    await service.addNote(
      targetId: 'M31',
      body: 'Polar alignment **was rough** at first. Then `dither` settled.',
      title: 'M31 first night',
    );

    await _pumpHost(
      tester,
      database: database,
      child: Builder(builder: (ctx) {
        final colors = SkotiqColors.of(ctx);
        return TargetNotesSection(targetId: 'M31', colors: colors);
      }),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    // Title (a plain Text) is still present.
    expect(find.text('M31 first night'), findsOneWidget);

    // Body must be a MarkdownBody, not a raw `Text(note.body)`, so **bold**
    // renders as bold rather than as literal asterisks.
    expect(find.byType(MarkdownBody), findsAtLeastNWidgets(1),
        reason: 'Note bodies must be rendered with MarkdownBody so '
            'inline markdown (**bold**, `code`, links) renders properly.');

    // The literal markdown source string with raw asterisks should
    // NOT appear as a plain Text — MarkdownBody parses them out into
    // RichText spans.
    expect(
      find.byWidgetPredicate((w) =>
          w is Text &&
          w.data ==
              'Polar alignment **was rough** at first. Then `dither` settled.'),
      findsNothing,
      reason: 'The plain Text(note.body) call must be gone — the body '
          'string now flows through MarkdownBody.',
    );
  });

  testWidgets(
      'preserves the empty-body code path (no MarkdownBody when '
      'body is empty)', (tester) async {
    final service = NotesService(database);
    await service.addNote(
      targetId: 'M31',
      body: '', // empty
      title: 'Title-only note',
    );

    await _pumpHost(
      tester,
      database: database,
      child: Builder(builder: (ctx) {
        final colors = SkotiqColors.of(ctx);
        return TargetNotesSection(targetId: 'M31', colors: colors);
      }),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    // Title-only notes render the title (and timestamp) but no
    // MarkdownBody — the `if (note.body.isNotEmpty)` guard in
    // _NoteTile must still hold.
    expect(find.text('Title-only note'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing,
        reason: 'Empty bodies should not allocate a MarkdownBody widget.');
  });
}
