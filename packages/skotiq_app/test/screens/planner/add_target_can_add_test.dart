// "Add Target" has to be able to add a target.
//
// From a fresh profile the app's own instructions dead-ended: Schedule >
// "Open target catalog" -> Projects -> New project -> Add Target -> "No
// targets in the catalog. Add targets to your library first" — with no button,
// link or hint for how, and the only writer of the targets table reachable
// from the UI being Framing > Save target. The sheet now searches the
// installed sky catalogs as well as the library and creates the library row
// itself, so the flow terminates where the user actually is.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_app/screens/planner/widgets/projects_tab_content.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as ndb;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FakeActiveProjectNotifier extends ActiveProjectNotifier {
  // ignore: use_super_parameters
  _FakeActiveProjectNotifier(Ref ref, int? initial) : super(ref) {
    if (initial != null) state = initial;
  }

  @override
  Future<void> setActiveProject(int? id) async => state = id;
}

class _RecordingProjectService implements ProjectService {
  int? addedProjectId;
  int? addedTargetId;

  @override
  Future<void> addTarget({
    required int projectId,
    required int targetId,
    int? priorityOverride,
  }) async {
    addedProjectId = projectId;
    addedTargetId = targetId;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'Unexpected ProjectService call: ${invocation.memberName}');
}

/// Records what the sheet asked the library to create and hands back a row.
class _RecordingTargetLibrary implements TargetLibraryService {
  String? name;
  double? raHours;
  double? decDegrees;
  String? catalogId;

  @override
  Future<ndb.Target> ensureCatalogTarget({
    required String targetName,
    required double raHours,
    required double decDegrees,
    String? catalogId,
    String? objectType,
    String? constellation,
    double? magnitude,
    double? sizeArcmin,
  }) async {
    name = targetName;
    this.raHours = raHours;
    this.decDegrees = decDegrees;
    this.catalogId = catalogId;
    return ndb.Target(
      id: 77,
      name: targetName,
      ra: raHours,
      dec: decDegrees,
      minAltitude: 30,
      priority: 5,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 0,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      isFavorite: false,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'Unexpected TargetLibraryService call: ${invocation.memberName}');
}

/// Pins whether the OpenNGC catalog is installed without touching disk.
class _FakeCatalogState extends StateNotifier<CatalogState>
    implements CatalogStateNotifier {
  _FakeCatalogState({required bool dsoInstalled})
      : super(CatalogState(
          dsoCatalogStatus: CatalogStatus(isInstalled: dsoInstalled),
          isInitialized: true,
        ));

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'Unexpected CatalogStateNotifier call: ${invocation.memberName}');
}

Project _project({required int id, required String name}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
  return Project(
    id: id,
    name: name,
    createdAt: now,
    updatedAt: now,
  );
}

const _m31 = CatalogSearchResult(
  name: 'M31',
  catalogId: 'M31',
  ra: 10.68,
  dec: 41.27,
  type: 'Galaxy',
  magnitude: 3.4,
  constellation: 'And',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an empty library can still add a catalog target and attach it',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final project = _project(id: 3, name: 'Empty Campaign');
    final projectService = _RecordingProjectService();
    final library = _RecordingTargetLibrary();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectListProvider.overrideWith((ref) => Stream.value([project])),
          activeProjectIdProvider.overrideWith(
            (ref) => _FakeActiveProjectNotifier(ref, 3),
          ),
          activeProjectProgressProvider.overrideWith(
            (ref) async =>
                CampaignProgress(project: project, targets: const []),
          ),
          projectServiceProvider.overrideWithValue(projectService),
          targetLibraryServiceProvider.overrideWithValue(library),
          // The library is EMPTY — the case a sheet can most easily dead-end
          // on.
          allDbTargetsProvider.overrideWith(
            (ref) => Stream.value(const <ndb.Target>[]),
          ),
          installedCatalogSearchProvider.overrideWith(
            (ref, query) async =>
                query.toLowerCase().startsWith('m31') ? [_m31] : [],
          ),
          catalogStateProvider.overrideWith(
            (ref) => _FakeCatalogState(dsoInstalled: true),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ProjectsTabContent()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Add target').first);
    await tester.pumpAndSettle();

    // The empty state points at the action that works: search for the
    // object.
    expect(find.textContaining('Search for an object by name'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'M31');
    await tester.pumpAndSettle();

    expect(find.text('Not in your targets yet'), findsOneWidget);
    // Tap the row's subtitle: the search field also renders the text "M31".
    await tester.tap(find.text('Galaxy · mag 3.4 · And'));
    await tester.pumpAndSettle();

    // The sheet created the library row itself...
    expect(library.name, 'M31');
    expect(library.catalogId, 'M31');
    // ...in decimal HOURS, from a catalog result carrying degrees.
    expect(library.raHours, closeTo(10.68 / 15.0, 1e-9));
    expect(library.decDegrees, closeTo(41.27, 1e-9));
    // ...and the caller attached the new target to the open project.
    expect(projectService.addedProjectId, 3);
    expect(projectService.addedTargetId, 77);
  });

  // Nothing is bundled — OpenNGC is a download — so the fresh profile this
  // finding is about has an empty library AND no catalog. Telling that user to
  // "search for an object by name or catalog id" is the same dead end in nicer
  // words: there is nothing on the machine to search. The sheet must name the
  // cause and offer the download.
  testWidgets('with no catalog installed the sheet offers the download',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final project = _project(id: 3, name: 'Empty Campaign');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectListProvider.overrideWith((ref) => Stream.value([project])),
          activeProjectIdProvider.overrideWith(
            (ref) => _FakeActiveProjectNotifier(ref, 3),
          ),
          activeProjectProgressProvider.overrideWith(
            (ref) async =>
                CampaignProgress(project: project, targets: const []),
          ),
          projectServiceProvider.overrideWithValue(_RecordingProjectService()),
          targetLibraryServiceProvider
              .overrideWithValue(_RecordingTargetLibrary()),
          allDbTargetsProvider.overrideWith(
            (ref) => Stream.value(const <ndb.Target>[]),
          ),
          // No catalog on disk: the search can never return anything.
          installedCatalogSearchProvider.overrideWith(
            (ref, query) async => const <CatalogSearchResult>[],
          ),
          catalogStateProvider.overrideWith(
            (ref) => _FakeCatalogState(dsoInstalled: false),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ProjectsTabContent()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Add target').first);
    await tester.pumpAndSettle();

    expect(find.text('No sky catalog installed'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Open catalog settings'),
      findsOneWidget,
    );
    // The copy must not send the user hunting for something that cannot be
    // found.
    expect(find.textContaining('Search for an object by name'), findsNothing);

    // ...and it still does not fall back to the "nothing matches" phrasing
    // once the user types, which would be the same false claim with a query in
    // it.
    await tester.enterText(find.byType(TextField).last, 'M31');
    await tester.pumpAndSettle();
    expect(find.text('No sky catalog installed'), findsOneWidget);
    expect(find.textContaining('matches "M31"'), findsNothing);
  });
}
