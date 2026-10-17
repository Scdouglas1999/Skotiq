// Widget tests for the per-target notes panel + diff dialog.
//
// We don't spin up a full Drift backend: tests override the database
// provider with an in-memory SkotiqDatabase so the NotesService
// queries flow through real SQL but never touch the filesystem.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/notes_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_diff_dialog.dart';
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
  group('TargetNotesSection', () {
    late db.SkotiqDatabase database;

    setUp(() {
      database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('shows empty state when target has no notes', (tester) async {
      await _pumpHost(
        tester,
        database: database,
        child: Builder(builder: (ctx) {
          final colors = SkotiqColors.of(ctx);
          return TargetNotesSection(targetId: 'M31', colors: colors);
        }),
      );
      // Allow the stream + initial query to resolve.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.textContaining('No notes yet'), findsOneWidget);
      expect(find.text('Add note'), findsOneWidget);
    });

    testWidgets('renders existing notes for the target', (tester) async {
      final service = NotesService(database);
      await service.addNote(
        targetId: 'M31',
        body: 'Polar alignment was rough in the first hour.',
        title: 'M31 first night',
      );
      await service.addNote(
        targetId: 'M31',
        body: 'Guiding stabilised after 22:30.',
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
      expect(find.text('M31 first night'), findsOneWidget);
      expect(find.textContaining('Polar alignment was rough'), findsOneWidget);
      expect(find.textContaining('Guiding stabilised'), findsOneWidget);
    });
  });

  group('SequenceDiffDialog', () {
    testWidgets('renders empty diff with success state', (tester) async {
      const result = SequenceDiffResult(
        previousName: 'M31',
        currentName: 'M31',
        added: [],
        removed: [],
        modified: [],
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: SequenceDiffDialog(diff: result),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Sequence Diff'), findsOneWidget);
      expect(find.textContaining('No structural changes'), findsOneWidget);
    });

    testWidgets('renders added / removed / modified sections', (tester) async {
      const result = SequenceDiffResult(
        previousName: 'a',
        currentName: 'b',
        added: [
          NodeDiffEntry(
            nodeId: 'n1',
            nodeKind: 'TakeExposure',
            label: 'Exposure 120s x10 (Lum)',
            changes: [],
          ),
        ],
        removed: [
          NodeDiffEntry(
            nodeId: 'n2',
            nodeKind: 'Dither',
            label: 'Dither 5.0px',
            changes: [],
          ),
        ],
        modified: [
          NodeDiffEntry(
            nodeId: 'n3',
            nodeKind: 'TakeExposure',
            label: 'Exposure 60s x10 (Lum)',
            changes: [
              FieldChange('Exposure duration', '60.0s', '120.0s'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: SequenceDiffDialog(diff: result),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Added (1)'), findsOneWidget);
      expect(find.text('Removed (1)'), findsOneWidget);
      expect(find.text('Modified (1)'), findsOneWidget);
      expect(find.text('Exposure 120s x10 (Lum)'), findsOneWidget);
      expect(find.text('Dither 5.0px'), findsOneWidget);
      expect(find.text('60.0s'), findsOneWidget);
      expect(find.text('120.0s'), findsOneWidget);
      expect(find.text('Exposure duration'), findsOneWidget);
    });
  });
}
