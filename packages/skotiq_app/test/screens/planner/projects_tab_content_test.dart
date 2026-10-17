// Widget tests for the Projects tab (component C9).
//
// The full planning graph requires a real drift database (the projects /
// project_targets raw tables) and the captures/goals history, so we override
// the leaf providers the widget actually reads with deterministic doubles:
//
//   * projectListProvider          — the project selector source.
//   * activeProjectIdProvider      — the selected project (a fake notifier so
//     no settings DAO / database is touched).
//   * activeProjectProgressProvider — the per-target accrued-vs-goal roll-up.
//   * projectServiceProvider       — a fake that records create calls so the
//     "New Project" dialog flow can be asserted without a database.
//
// The planning roll-up is the barrel-exported `CampaignProgress` (named to
// avoid colliding with the legacy analytics ProjectProgress), so the test seeds
// the progress provider with it straight off the skotiq_core barrel.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:skotiq_app/screens/planner/widgets/projects_tab_content.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A fake [ActiveProjectNotifier] that holds a fixed selection in memory and
/// records the last id passed to [setActiveProject], so the create-project flow
/// can be asserted without a settings DAO. Subclasses the real notifier (rather
/// than a bare [StateNotifier]) because the provider is typed to
/// [ActiveProjectNotifier] and `ref.read(provider.notifier)` casts to it.
class _FakeActiveProjectNotifier extends ActiveProjectNotifier {
  // The base ctor takes a private positional (`_ref`), which a super-parameter
  // cannot forward to, so the explicit parameter is required here.
  // ignore: use_super_parameters
  _FakeActiveProjectNotifier(Ref ref, int? initial) : super(ref) {
    if (initial != null) state = initial;
  }

  int? lastSetId;
  int setCallCount = 0;
  bool failWrites = false;

  @override
  Future<void> setActiveProject(int? id) async {
    setCallCount++;
    lastSetId = id;
    if (failWrites) throw StateError('write failed');
    state = id;
  }
}

/// A fake [ProjectService] that records [createProject] arguments. Only the
/// methods exercised by the create flow are implemented; everything else throws
/// (fail-loud) so an accidental call surfaces in a test rather than silently
/// succeeding.
class _FakeProjectService implements ProjectService {
  String? createdName;
  String? createdDescription;
  int nextId;
  int createCallCount = 0;
  Completer<int>? createCompleter;

  _FakeProjectService({this.nextId = 99, this.createCompleter});

  @override
  Future<int> createProject({
    required String name,
    String? description,
    int? colorArgb,
  }) async {
    createCallCount++;
    createdName = name;
    createdDescription = description;
    final completer = createCompleter;
    if (completer != null) return completer.future;
    return nextId;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected ProjectService call: '
          '${invocation.memberName}');
}

Project _project({required int id, required String name, String? description}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
  return Project(
    id: id,
    name: name,
    description: description,
    createdAt: now,
    updatedAt: now,
  );
}

ProjectTargetProgress _targetProgress({
  required int targetId,
  required String name,
  required int goalFrames,
  required int capturedFrames,
  double exposureSeconds = 300.0,
}) {
  return ProjectTargetProgress(
    targetId: targetId,
    targetName: name,
    raHours: 5.5,
    decDegrees: -5.0,
    filters: [
      FilterProgressLine(
        filter: 'L',
        exposureSeconds: exposureSeconds,
        goalFrames: goalFrames,
        capturedFrames: capturedFrames,
      ),
    ],
  );
}

Widget _harness({required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(
        body: SizedBox(
          width: 1000,
          height: 800,
          child: ProjectsTabContent(),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the no-campaigns empty state when no projects exist',
      (tester) async {
    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value(const [])),
        activeProjectIdProvider.overrideWith(
          (ref) => _FakeActiveProjectNotifier(ref, null),
        ),
        activeProjectProgressProvider.overrideWith((ref) async => null),
      ],
    ));
    await tester.pumpAndSettle();

    // One word for one object: an empty state reading "No campaigns yet" above
    // a body that says "project" and a button that says "New Project" names the
    // same thing three ways.
    expect(find.text('No projects yet'), findsOneWidget);
    expect(find.textContaining('campaign'), findsNothing);
    expect(
        find.widgetWithText(SkotiqButton, 'New project'), findsOneWidget);
  });

  testWidgets(
      'renders per-target accrued/goal hours and percent for seeded progress',
      (tester) async {
    final project = _project(id: 1, name: 'Winter Nebulae');
    // 10 of 20 frames at 300s/frame -> 50%; accrued 10*300=3000s=0.8h... wire
    // the numbers so the formatted labels are deterministic: 24 captured of 48
    // at 300s -> 50%, accrued 24*300=7200s=2.0h, goal 48*300=14400s=4.0h.
    final progress = CampaignProgress(
      project: project,
      targets: [
        _targetProgress(
          targetId: 10,
          name: 'Orion Nebula',
          goalFrames: 48,
          capturedFrames: 24,
        ),
      ],
    );

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value([project])),
        activeProjectIdProvider.overrideWith(
          (ref) => _FakeActiveProjectNotifier(ref, 1),
        ),
        activeProjectProgressProvider.overrideWith((ref) async => progress),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Orion Nebula'), findsOneWidget);
    // Per-target accrued / goal label.
    expect(find.text('2.0h / 4.0h'), findsOneWidget);
    // Per-target percent label (50%). The project summary header also shows a
    // 50% telemetry figure, so expect at least one.
    expect(find.text('50%'), findsWidgets);
    // Per-filter breakdown chip captured/goal frames.
    expect(find.text('24 / 48'), findsOneWidget);
  });

  testWidgets('completed target shows a completion indicator', (tester) async {
    final project = _project(id: 2, name: 'Galaxy Season');
    final progress = CampaignProgress(
      project: project,
      targets: [
        _targetProgress(
          targetId: 20,
          name: 'Whirlpool Galaxy',
          goalFrames: 30,
          capturedFrames: 30, // fully complete
        ),
      ],
    );

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value([project])),
        activeProjectIdProvider.overrideWith(
          (ref) => _FakeActiveProjectNotifier(ref, 2),
        ),
        activeProjectProgressProvider.overrideWith((ref) async => progress),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Whirlpool Galaxy'), findsOneWidget);
    // The success StatusPill renders its value-only ('Complete') text.
    expect(find.text('Complete'), findsOneWidget);
    // "1 complete" in the project summary, colored success.
    expect(find.textContaining('1 complete'), findsOneWidget);
  });

  testWidgets('failed project selection stays unchanged and reports the error',
      (tester) async {
    final first = _project(id: 1, name: 'Winter Nebulae');
    final second = _project(id: 2, name: 'Galaxy Season');
    late _FakeActiveProjectNotifier activeNotifier;
    final progress = CampaignProgress(project: first, targets: const []);

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith(
          (ref) => Stream.value([first, second]),
        ),
        activeProjectIdProvider.overrideWith((ref) {
          activeNotifier = _FakeActiveProjectNotifier(ref, 1)
            ..failWrites = true;
          return activeNotifier;
        }),
        activeProjectProgressProvider.overrideWith((ref) async => progress),
      ],
    ));
    await tester.pumpAndSettle();

    // The kit's select owns its own popover now (it replaced Material's
    // DropdownButton, whose 48 px entry floor it could not honour), so the
    // finder is the kit type rather than the Material one.
    await tester.tap(find.byType(SkotiqDropdown));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Galaxy Season').last);
    await tester.pumpAndSettle();

    expect(activeNotifier.lastSetId, 2);
    expect(activeNotifier.state, 1);
    expect(find.text('Could not save the active project.'), findsOneWidget);
  });

  testWidgets('"New Project" opens the create dialog', (tester) async {
    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value(const [])),
        activeProjectIdProvider.overrideWith(
          (ref) => _FakeActiveProjectNotifier(ref, null),
        ),
        activeProjectProgressProvider.overrideWith((ref) async => null),
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'New project'));
    await tester.pumpAndSettle();

    // The dialog scaffold shows its title and name field.
    expect(
        find.widgetWithText(SkotiqDialog, 'New project'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Create'), findsOneWidget);
    expect(find.byIcon(LucideIcons.folder), findsWidgets);
  });

  testWidgets('creating a project persists it and sets it active',
      (tester) async {
    final service = _FakeProjectService(nextId: 77);
    late _FakeActiveProjectNotifier activeNotifier;

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value(const [])),
        activeProjectIdProvider.overrideWith((ref) {
          activeNotifier = _FakeActiveProjectNotifier(ref, null);
          return activeNotifier;
        }),
        activeProjectProgressProvider.overrideWith((ref) async => null),
        projectServiceProvider.overrideWithValue(service),
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'New project'));
    await tester.pumpAndSettle();

    // Type a name into the name field (the first text field in the dialog).
    await tester.enterText(find.byType(TextField).first, 'Comet Hunt');
    await tester.tap(find.widgetWithText(SkotiqButton, 'Create'));
    await tester.pumpAndSettle();

    expect(service.createdName, 'Comet Hunt');
    expect(activeNotifier.lastSetId, 77);
    expect(activeNotifier.setCallCount, greaterThan(0));
  });

  testWidgets('project creation is single-flight after the dialog closes',
      (tester) async {
    final createCompleter = Completer<int>();
    final service = _FakeProjectService(createCompleter: createCompleter);
    late _FakeActiveProjectNotifier activeNotifier;

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value(const [])),
        activeProjectIdProvider.overrideWith((ref) {
          activeNotifier = _FakeActiveProjectNotifier(ref, null);
          return activeNotifier;
        }),
        activeProjectProgressProvider.overrideWith((ref) async => null),
        projectServiceProvider.overrideWithValue(service),
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'New project'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Slow Project');
    await tester.tap(find.widgetWithText(SkotiqButton, 'Create'));
    await tester.pump();

    expect(service.createCallCount, 1);
    final busyButton = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'New project'),
    );
    expect(busyButton.isLoading, isTrue);
    expect(busyButton.onPressed, isNull);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'New project'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(service.createCallCount, 1);

    createCompleter.complete(88);
    await tester.pumpAndSettle();
    expect(activeNotifier.lastSetId, 88);
  });

  testWidgets('shows the add-target prompt when a project has no targets',
      (tester) async {
    final project = _project(id: 3, name: 'Empty Campaign');
    final progress = CampaignProgress(project: project, targets: const []);

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value([project])),
        activeProjectIdProvider.overrideWith(
          (ref) => _FakeActiveProjectNotifier(ref, 3),
        ),
        activeProjectProgressProvider.overrideWith((ref) async => progress),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('No targets yet'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Add target'), findsWidgets);
  });

  testWidgets(
      '"Plan Tonight" opens the wizard seeded with the active '
      "project's incomplete targets (C11 handoff)", (tester) async {
    final project = _project(id: 5, name: 'Galaxy Season');
    // Two targets: one incomplete (id 50), one complete (id 51). Only the
    // incomplete one should be seeded into the wizard.
    final progress = CampaignProgress(
      project: project,
      targets: [
        _targetProgress(
          targetId: 50,
          name: 'M51',
          goalFrames: 40,
          capturedFrames: 10, // incomplete
        ),
        _targetProgress(
          targetId: 51,
          name: 'M101',
          goalFrames: 20,
          capturedFrames: 20, // complete -> excluded from the seed
        ),
      ],
    );

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value([project])),
        activeProjectIdProvider.overrideWith(
          (ref) => _FakeActiveProjectNotifier(ref, 5),
        ),
        activeProjectProgressProvider.overrideWith((ref) async => progress),
        // The seeded SmartNightDialog renders step 1 (Window) first; with no
        // observer location it shows the missing-location card without touching
        // suggestions/DB, so the dialog mounts cleanly in the test.
        appObserverLocationProvider.overrideWithValue(null),
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Plan tonight'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The wizard opened.
    expect(find.byType(SmartNightDialog), findsOneWidget);
    final dialog =
        tester.widget<SmartNightDialog>(find.byType(SmartNightDialog));
    // Seeded with ONLY the incomplete target (50), not the complete one (51).
    expect(dialog.seedTargetIds, [50]);
    expect(dialog.seedSourceLabel, 'Galaxy Season');
  });

  testWidgets('Plan Tonight discards a roll-up after the project changes',
      (tester) async {
    final first = _project(id: 5, name: 'Galaxy Season');
    final second = _project(id: 6, name: 'Nebula Season');
    final progressCompleter = Completer<CampaignProgress?>();
    late _FakeActiveProjectNotifier activeNotifier;

    await tester.pumpWidget(_harness(
      overrides: [
        projectListProvider.overrideWith(
          (ref) => Stream.value([first, second]),
        ),
        activeProjectIdProvider.overrideWith((ref) {
          activeNotifier = _FakeActiveProjectNotifier(ref, 5);
          return activeNotifier;
        }),
        activeProjectProgressProvider.overrideWith(
          (ref) => progressCompleter.future,
        ),
        appObserverLocationProvider.overrideWithValue(null),
      ],
    ));
    await tester.pump();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Plan tonight'));
    await tester.pump();
    await activeNotifier.setActiveProject(6);
    await tester.pump();

    progressCompleter.complete(
      CampaignProgress(
        project: first,
        targets: [
          _targetProgress(
            targetId: 50,
            name: 'M51',
            goalFrames: 40,
            capturedFrames: 10,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SmartNightDialog), findsNothing);
    expect(
      find.text(
        'The active project changed while its plan was loading. Try again.',
      ),
      findsOneWidget,
    );
  });
}
