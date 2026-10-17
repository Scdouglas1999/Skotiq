// Pre-flight dialog surfaces a "View changes" link when
// the in-editor sequence has diverged structurally from the last
// COMPLETED run. The link opens the SequenceDiffDialog (which is
// covered by separate tests in notes_panel_test.dart for the
// shape-of-result rendering).
//
// We don't drive a full sequence_runs DAO + repository round-trip
// here: the diff-resolution path is best-effort and quietly skips on
// any DB-shape mismatch (see _computePreviousRunDiff in
// preflight_validation_dialog.dart). Instead we override
// `sequenceDiffServiceProvider` with a fake that returns a canned
// non-empty diff, and override the DAO/repo paths just enough to
// short-circuit them into returning the inputs the diff service
// consumes. The widget test then checks that the banner string and
// "View changes" link are visible.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _FakeValidator implements SequenceValidatorService {
  _FakeValidator(this._result);
  final ValidationResult _result;

  @override
  Future<ValidationResult> validate(Sequence sequence) async => _result;

  @override
  ValidationResult validateSync(Sequence sequence) => _result;
}

class _FakeDiffService implements SequenceDiffService {
  _FakeDiffService(this._result);
  final SequenceDiffResult _result;

  @override
  SequenceDiffResult diff({
    required Sequence previous,
    required Sequence current,
  }) =>
      _result;
}

class _FakeSequenceRepository implements SequenceRepository {
  _FakeSequenceRepository(this.sequence);

  final Sequence sequence;

  @override
  Future<Sequence?> loadSequence(int sequenceId) async => sequence;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ValidationResult _emptyResult() =>
    ValidationResult(issues: const [], validatedAt: DateTime(2026, 1, 1));

Sequence _sequence({int? databaseId}) {
  final root = InstructionSetNode(name: 'root');
  final expo = ExposureNode().copyWith(parentId: root.id);
  final placedRoot = root.copyWith(childIds: [expo.id]);
  return Sequence.create(
    name: 'Test',
    nodes: {placedRoot.id: placedRoot, expo.id: expo},
    rootNodeId: placedRoot.id,
    databaseId: databaseId,
  );
}

class _SeedingNotifier extends CurrentSequenceNotifier {
  _SeedingNotifier(Ref ref, Sequence seed) : super(ref: ref) {
    loadSequence(seed, discardUnsaved: true);
  }
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 40,
        longitude: -75,
      );
}

Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(1200, 1000)),
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'shows diff banner with "View changes" link when diff is non-empty',
      (tester) async {
    // A non-empty diff: one added + one modified node.
    const diff = SequenceDiffResult(
      previousName: 'Test (last run)',
      currentName: 'Test',
      added: [
        NodeDiffEntry(
          nodeId: 'added-1',
          nodeKind: 'ExposureNode',
          label: 'Exposure 120s · Ha',
          changes: [],
        ),
      ],
      removed: [],
      modified: [
        NodeDiffEntry(
          nodeId: 'modified-1',
          nodeKind: 'ExposureNode',
          label: 'Exposure 60s · L',
          changes: [
            FieldChange('Exposure duration', '60.0s', '90.0s'),
          ],
        ),
      ],
    );

    final persistedSequence = _sequence(databaseId: 42);
    final completedRun = SequenceRun(
      id: 7,
      sequenceId: 42,
      sequenceName: 'Test',
      startedAt: DateTime.utc(2026, 1, 1),
      endedAt: DateTime.utc(2026, 1, 1, 1),
      status: 'completed',
      statsJson: '{}',
    );

    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, _sequence(databaseId: 42)),
      ),
      sequenceRunsForSequenceProvider.overrideWith(
        (ref, sequenceId) => Stream.value([completedRun]),
      ),
      sequenceRepositoryProvider.overrideWithValue(
        _FakeSequenceRepository(persistedSequence),
      ),
      sequenceValidatorProvider
          .overrideWith((ref) => _FakeValidator(_emptyResult())),
      sequenceDiffServiceProvider.overrideWithValue(_FakeDiffService(diff)),
      appSettingsProvider.overrideWith(() => _FakeAppSettingsNotifier()),
    ]);
    addTearDown(container.dispose);

    await tester
        .pumpWidget(_wrap(container, const PreFlightValidationDialog()));
    await tester.pumpAndSettle();

    expect(find.text('Pre-flight check'), findsOneWidget,
        reason: 'Header must render regardless of diff state.');
    expect(
      find.textContaining(
        'Sequence has changed since last successful run',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('View changes'), findsOneWidget);
    // The summary tile renders one of three statuses depending on what
    // the (real) PreSessionSimulator reports. The validator override
    // returns an empty ValidationResult, but the simulator runs against
    // the actual wall clock and can emit a warning when the sequence
    // would start before astronomical dusk. Either "All checks passed"
    // or "Ready with warnings" is acceptable here — what matters is
    // that the dialog escaped the loading state and rendered a tile.
    expect(
      find.text('All checks passed', findRichText: true).evaluate().length +
          find
              .text('Ready with warnings', findRichText: true)
              .evaluate()
              .length,
      1,
      reason: 'Empty validation result must surface a non-error verdict banner '
          '(either "All checks passed" or "Ready with warnings" depending '
          'on the live PreSessionSimulator).',
    );
  });

  testWidgets(
      'renders header without the diff banner when sequence is '
      'unsaved (no databaseId)', (tester) async {
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, _sequence(databaseId: null)),
      ),
      sequenceValidatorProvider
          .overrideWith((ref) => _FakeValidator(_emptyResult())),
      appSettingsProvider.overrideWith(() => _FakeAppSettingsNotifier()),
    ]);
    addTearDown(container.dispose);

    await tester
        .pumpWidget(_wrap(container, const PreFlightValidationDialog()));
    await tester.pumpAndSettle();

    // No databaseId => the diff path returns early and the banner
    // never appears. Verify the dialog still works end-to-end.
    expect(find.text('Pre-flight check'), findsOneWidget);
    // Same rationale as the previous case: accept either summary tile
    // since the live PreSessionSimulator may warn depending on the
    // current wall-clock-vs-dark-window relationship.
    expect(
      find.text('All checks passed', findRichText: true).evaluate().length +
          find
              .text('Ready with warnings', findRichText: true)
              .evaluate()
              .length,
      1,
    );
    expect(find.textContaining('Sequence has changed', findRichText: true),
        findsNothing,
        reason: 'No previous-run diff banner for an unsaved sequence.');
  });
}
