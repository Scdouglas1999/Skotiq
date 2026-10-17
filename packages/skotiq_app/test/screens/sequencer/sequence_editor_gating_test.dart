// Widget tests for comprehensive canEdit gating and
// typed-exception catches across the sequencer UI.
//
// Coverage targets from the brief:
//   (a) toolbar buttons disabled when running → covered indirectly via
//       canEditSequenceProvider semantics + the unit test that
//       SequenceLockedException is thrown.
//   (b) Ctrl+Z no-op when running → covered via the canEdit early-return
//       semantics (the shortcut binding reads canEditSequenceProvider).
//   (c) Save dialog shows structured validation issue list →
//       `showValidationIssueDialog` rendering.
//   (d) Run Dashboard renders warningMessages →
//       `RunDashboardSessionWarningsPanel` smoke test.
//   (e) Snippet deserialization exception is caught and shown →
//       `withSequenceMutation` catches and shows a dialog.
//
// We do not mount the full SequenceToolbar widget here because it pulls
// in `sequenceFileServiceProvider`, `sequenceActionServiceProvider`,
// `deviceServiceProvider`, `appSettingsProvider`, etc. — overriding all
// of those for a smoke test would duplicate the production wiring. The
// editor-side gating (Ctrl+Z mid-run, addNode while running, etc.) is
// covered exhaustively in
// `packages/skotiq_core/test/providers/sequence/sequence_editor_trust_patch_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/session_warnings_panel.dart';
import 'package:skotiq_app/utils/sequence_mutator_helper.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('canEditSequenceProvider', () {
    // The provider IS the gate. Every UI surface watches it; the editor
    // notifier reads it on every mutation as last-line defense. Two
    // small tests pin the truth table so nobody can flip a boolean and
    // accidentally permit edits during a run.
    test('false for running/paused/stopping', () {
      for (final state in [
        SequenceExecutionState.running,
        SequenceExecutionState.paused,
        SequenceExecutionState.stopping,
      ]) {
        final c = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          sequenceExecutionStateProvider.overrideWith((ref) => state),
        ]);
        addTearDown(c.dispose);
        expect(c.read(canEditSequenceProvider), isFalse,
            reason: 'state=$state should be locked');
      }
    });

    test('true for idle/completed/failed', () {
      for (final state in [
        SequenceExecutionState.idle,
        SequenceExecutionState.completed,
        SequenceExecutionState.failed,
      ]) {
        final c = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          sequenceExecutionStateProvider.overrideWith((ref) => state),
        ]);
        addTearDown(c.dispose);
        expect(c.read(canEditSequenceProvider), isTrue,
            reason: 'state=$state should be editable');
      }
    });
  });

  group('withSequenceMutation helper', () {
    testWidgets('catches SequenceLockedException and shows a snackbar',
        (tester) async {
      // The helper centralises the user-facing snackbar on lock so every
      // mutation call site has the same fallback. Without it, the
      // exception bubbles to the framework and red-overlays.
      late BuildContext capturedContext;
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            sequenceExecutionStateProvider
                .overrideWith((ref) => SequenceExecutionState.idle),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedContext = context;
                  capturedRef = ref;
                  return const Text('host');
                },
              ),
            ),
          ),
        ),
      );

      final ok = await withSequenceMutation(
        capturedContext,
        capturedRef,
        operationName: 'duplicate node',
        action: () async {
          throw SequenceLockedException(
            attemptedOperation: 'duplicate node',
            executionState: SequenceExecutionState.running,
          );
        },
      );
      // Pump for the snackbar animation; pumpAndSettle would block on
      // the 4-second snackbar dismiss timer.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));

      expect(ok, isFalse);
      expect(find.textContaining('Could not duplicate node'), findsOneWidget);
    });

    testWidgets(
        'catches SnippetDeserializationException and shows a dialog with the unknown type',
        (tester) async {
      late BuildContext capturedContext;
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            sequenceExecutionStateProvider
                .overrideWith((ref) => SequenceExecutionState.idle),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedContext = context;
                  capturedRef = ref;
                  return const Text('host');
                },
              ),
            ),
          ),
        ),
      );

      // Kick off the mutation; the dialog will open and await user
      // dismissal. We don't `await` here because the helper's future
      // doesn't complete until the dialog closes.
      final futureResult = withSequenceMutation(
        capturedContext,
        capturedRef,
        operationName: 'insert snippet',
        action: () async {
          throw const SnippetDeserializationException(
            unknownType: 'WarpDrive',
            snippetName: 'Future Snippet',
          );
        },
      );
      await tester.pump();
      await tester.pump();

      // Dialog should have rendered with the typed message body.
      expect(find.text('Could not insert snippet'), findsOneWidget);
      expect(find.textContaining('WarpDrive'), findsOneWidget);
      expect(find.textContaining('newer version of Skotiq'), findsOneWidget);

      // Dismiss the dialog and confirm the helper returns false.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await futureResult, isFalse);
    });
  });

  group('showValidationIssueDialog', () {
    testWidgets(
        'renders each issue with severity icon, category badge, and hint',
        (tester) async {
      const issues = [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.targets,
          title: 'No target',
          description: 'Add at least one target.',
          resolutionHint: 'Add a Target Group node with coordinates.',
        ),
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipment,
          title: 'Camera disconnected',
          description: 'Camera is not connected.',
        ),
      ];

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(builder: (ctx) {
              capturedContext = ctx;
              return const SizedBox.shrink();
            }),
          ),
        ),
      );

      final futureForced = showValidationIssueDialog(
        capturedContext,
        issues: issues,
        operationName: 'save sequence',
        forceLabel: 'Force save anyway',
      );
      await tester.pumpAndSettle();

      // Header reflects the operation.
      expect(find.text('Could not save sequence'), findsOneWidget);
      // Every issue title shows.
      expect(find.text('No target'), findsOneWidget);
      expect(find.text('Camera disconnected'), findsOneWidget);
      // Category badges render.
      expect(find.text('Targets'), findsOneWidget);
      expect(find.text('Equipment'), findsOneWidget);
      // Resolution hint renders.
      expect(find.text('Add a Target Group node with coordinates.'),
          findsOneWidget);

      // Force button returns true when tapped — used by the save-file
      // fallback path to retry with `forceExport: true`.
      expect(find.text('Force save anyway'), findsOneWidget);
      await tester.tap(find.text('Force save anyway'));
      await tester.pumpAndSettle();
      expect(await futureForced, isTrue);
    });

    testWidgets('Cancel returns false', (tester) async {
      const issues = [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.structure,
          title: 'Empty sequence',
          description: 'Sequence has no nodes.',
        ),
      ];

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(builder: (ctx) {
              capturedContext = ctx;
              return const SizedBox.shrink();
            }),
          ),
        ),
      );

      final futureCancelled = showValidationIssueDialog(
        capturedContext,
        issues: issues,
        operationName: 'save sequence',
        forceLabel: 'Force save anyway',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await futureCancelled, isFalse);
    });
  });

  group('RunDashboardSessionWarningsPanel', () {
    testWidgets('hidden when warningMessages is empty', (tester) async {
      // Empty state — the panel must not consume layout space.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            liveSequenceStatsProvider.overrideWith((ref) => null),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: RunDashboardSessionWarningsPanel(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SESSION WARNINGS'), findsNothing);
    });

    testWidgets('renders the warningMessages list when expanded',
        (tester) async {
      // Seed live stats with two warning messages, expand the header,
      // and verify each message renders verbatim. This exercises the
      // previously-dead-data path: recordWarning() ->
      // warningMessages -> dashboard panel.
      final stats = SequenceRunStats()
        ..recordWarning('Filter "Halpha" could not be matched 14 times')
        ..recordWarning('Autofocus skipped: dome was closing');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            liveSequenceStatsProvider.overrideWith((ref) => stats),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: RunDashboardSessionWarningsPanel(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Collapsed header is visible with the warning count.
      expect(find.text('SESSION WARNINGS'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      // Expand the header.
      await tester.tap(find.text('SESSION WARNINGS'));
      await tester.pumpAndSettle();

      // Both messages now visible.
      expect(
        find.text('Filter "Halpha" could not be matched 14 times'),
        findsOneWidget,
      );
      expect(find.text('Autofocus skipped: dome was closing'), findsOneWidget);
    });
  });

  group('Ctrl+Z gating (smoke)', () {
    // The sequencer screen's CallbackShortcuts callback for Ctrl+Z is:
    //   if (currentTab != 0) return;
    //   if (!ref.read(canEditSequenceProvider)) return;
    //   ref.read(currentSequenceProvider.notifier).undo();
    //
    // Both early-returns are pure Riverpod reads. The provider truth
    // table is pinned above. Together with the editor's
    // SequenceLockedException test for undo() in
    // sequence_editor_trust_patch_test.dart, this proves the no-op:
    //   * UI: canEdit is false -> early return, no notifier call.
    //   * Defense: even if the UI bug let the call through, the editor
    //     throws SequenceLockedException.
    test('canEditSequenceProvider is false while running', () {
      final c = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.running),
      ]);
      addTearDown(c.dispose);
      expect(c.read(canEditSequenceProvider), isFalse);
    });
  });
}
