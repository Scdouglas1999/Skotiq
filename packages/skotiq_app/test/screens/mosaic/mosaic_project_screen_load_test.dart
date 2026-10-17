// Regression tests for the Mosaic project review screen's ENTRY path — the one
// the router actually uses (`MosaicProjectScreen(projectId: id)` with no
// injected path builders, so the durable artifacts directory is resolved async).
//
// `MosaicProjectControllerArgs` is the controller family's key, so every field
// on it must be VALUE-comparable. A closure is rebuilt on every `build` and
// never compares equal, so each frame creates a fresh `MosaicProjectController`,
// whose constructor kicks a `load()`, whose completion rebuilds the screen — an
// unbounded rebuild/DB-read loop that pins the CPU behind a spinner.
//
// These tests pin three things:
//   1. exactly ONE controller is created for the screen's lifetime (no loop);
//   2. the screen reaches a usable, rendered state (no indefinite spinner);
//   3. every state the screen can be in — including the failure states — keeps
//      a back affordance so the operator is never trapped.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Counts how many distinct `mosaicProjectControllerProvider` family instances
/// the container ever initialised. One screen visit must produce exactly one.
class _ControllerCountingObserver extends ProviderObserver {
  final List<Object?> arguments = [];

  @override
  void didAddProvider(
    ProviderBase<Object?> provider,
    Object? value,
    ProviderContainer container,
  ) {
    final argument = provider.argument;
    if (argument is MosaicProjectControllerArgs) {
      arguments.add(argument);
    }
  }

  /// Distinct-by-`==` keys, i.e. how many controllers the family really made.
  int get distinctArgs => arguments.toSet().length;
}

/// The header's back control. It is icon-only now (the "< Back" bar was a
/// second header row), so it is found by its glyph and named by its tooltip.
final Finder _backAction = find.byWidgetPredicate(
  (widget) =>
      widget is SkotiqIconButton && widget.icon == SkotiqIcons.arrowLeft,
);

void main() {
  late SkotiqDatabase db;
  late MosaicProjectsDao projectsDao;
  late MosaicPanelsDao panelsDao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    projectsDao = MosaicProjectsDao(db);
    panelsDao = MosaicPanelsDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedProject() async {
    final projectId =
        await projectsDao.create(name: 'Veil Mosaic', rows: 1, cols: 2);
    for (var i = 0; i < 2; i++) {
      await panelsDao.upsert(
        projectId: projectId,
        panelIndex: i,
        centerRa: 20.0 + i * 0.1,
        centerDec: 30.0,
      );
    }
    return projectId;
  }

  /// Pumps the screen exactly as the router builds it: no injected builders, so
  /// the durable artifacts base resolves through
  /// [mosaicArtifactsBaseDirProvider] (overridden here so the test never touches
  /// `path_provider`).
  Future<_ControllerCountingObserver> pumpRouterScreen(
    WidgetTester tester,
    int projectId, {
    AsyncValue<String>? baseDirOverride,
  }) async {
    final observer = _ControllerCountingObserver();
    await tester.pumpWidget(
      ProviderScope(
        observers: [observer],
        overrides: [
          databaseProvider.overrideWithValue(db),
          constellationConfiguredProvider.overrideWith((ref) async => false),
          mosaicArtifactsBaseDirProvider.overrideWith(
            (ref) async => '/tmp/skotiq_mosaic_test',
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: MosaicProjectScreen(projectId: projectId),
        ),
      ),
    );
    // No pumpAndSettle: a rebuild loop never settles, and that is the very bug
    // under test — pump a fixed budget of frames instead.
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return observer;
  }

  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(microseconds: 1));
  }

  testWidgets('router entry builds ONE controller and settles (no loop)',
      (tester) async {
    final projectId = await seedProject();
    final observer = await pumpRouterScreen(tester, projectId);

    // The loop signature: one controller per frame. One screen = one controller
    // (the family key is value-stable, so the same key is reused).
    expect(observer.distinctArgs, 1);

    // ...and the screen actually reached a usable state.
    expect(
        find.byWidgetPredicate((w) =>
            w is SkotiqMark && w.motion == SkotiqMarkMotion.loading ||
            w is SkotiqSpinner),
        findsNothing);
    expect(find.text('Veil Mosaic'), findsOneWidget);

    // Frames keep flowing without producing new work.
    final settled = observer.arguments.length;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(observer.arguments.length, settled);

    await disposeScreen(tester);
  });

  testWidgets('a missing project shows an explicit error, never a spinner',
      (tester) async {
    // id 9999 does not exist: the load resolves "not found". This used to spin
    // forever because each rebuild made a fresh, freshly-loading controller.
    final observer = await pumpRouterScreen(tester, 9999);

    expect(observer.distinctArgs, 1);
    expect(
        find.byWidgetPredicate((w) =>
            w is SkotiqMark && w.motion == SkotiqMarkMotion.loading ||
            w is SkotiqSpinner),
        findsNothing);
    expect(find.text('Mosaic project not found'), findsOneWidget);

    await disposeScreen(tester);
  });

  testWidgets(
      'artifacts-directory failure is an actionable error, not a spinner',
      (tester) async {
    final projectId = await seedProject();
    final observer = _ControllerCountingObserver();
    await tester.pumpWidget(
      ProviderScope(
        observers: [observer],
        overrides: [
          databaseProvider.overrideWithValue(db),
          constellationConfiguredProvider.overrideWith((ref) async => false),
          mosaicArtifactsBaseDirProvider.overrideWith(
            (ref) async => throw StateError('no support dir'),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: MosaicProjectScreen(projectId: projectId),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
        find.byWidgetPredicate((w) =>
            w is SkotiqMark && w.motion == SkotiqMarkMotion.loading ||
            w is SkotiqSpinner),
        findsNothing);
    expect(find.text('Mosaic storage unavailable'), findsOneWidget);
    // No controller is built when the storage cannot be resolved.
    expect(observer.arguments, isEmpty);

    await disposeScreen(tester);
  });

  testWidgets(
      're-entering re-reads the project (cached controller, no stale '
      'snapshot)', (tester) async {
    // The controller family is cached on a value-stable key, so a second visit
    // reuses the first visit's controller. It must still show what the database
    // says NOW — panels captured/integrated while the operator was on another
    // screen are the whole point of the review screen.
    final projectId = await seedProject();
    final observer = _ControllerCountingObserver();

    Future<void> openProject() async {
      await tester.tap(find.text('open'));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        observers: [observer],
        overrides: [
          databaseProvider.overrideWithValue(db),
          constellationConfiguredProvider.overrideWith((ref) async => false),
          mosaicArtifactsBaseDirProvider.overrideWith(
            (ref) async => '/tmp/skotiq_mosaic_test',
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MosaicProjectScreen(projectId: projectId),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await openProject();
    expect(find.textContaining('Planning'), findsOneWidget);

    // Leave, and let the world move on underneath.
    await tester.tap(_backAction);
    await tester.pump(const Duration(milliseconds: 400));
    await projectsDao.updateStatus(projectId, MosaicProjectStatus.capturing);

    await openProject();
    expect(find.textContaining('Capturing'), findsOneWidget);
    expect(find.textContaining('Planning'), findsNothing);
    // Still exactly one controller — the refresh reuses it, never re-keys.
    expect(observer.distinctArgs, 1);

    await disposeScreen(tester);
  });

  testWidgets('every screen state keeps a back affordance', (tester) async {
    // Pushed on top of a route, the screen must never be a dead end: loading,
    // loaded, not-found and storage-error all keep app chrome with a back
    // button.
    Future<void> pumpPushed({
      required int projectId,
      required Override baseDir,
    }) async {
      // Each phase gets a fresh tree (and so a fresh provider container), so an
      // earlier phase's resolved artifacts dir cannot leak into the next.
      await disposeScreen(tester);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            databaseProvider.overrideWithValue(db),
            constellationConfiguredProvider.overrideWith((ref) async => false),
            baseDir,
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MosaicProjectScreen(
                          projectId: projectId,
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    final projectId = await seedProject();

    // Loaded state.
    await pumpPushed(
      projectId: projectId,
      baseDir: mosaicArtifactsBaseDirProvider.overrideWith(
        (ref) async => '/tmp/skotiq_mosaic_test',
      ),
    );
    expect(_backAction, findsOneWidget);
    await tester.tap(_backAction);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('open'), findsOneWidget);

    // Storage-failure state.
    await pumpPushed(
      projectId: projectId,
      baseDir: mosaicArtifactsBaseDirProvider.overrideWith(
        (ref) async => throw StateError('no support dir'),
      ),
    );
    expect(find.text('Mosaic storage unavailable'), findsOneWidget);
    expect(_backAction, findsOneWidget);

    // Not-found state.
    await pumpPushed(
      projectId: 9999,
      baseDir: mosaicArtifactsBaseDirProvider.overrideWith(
        (ref) async => '/tmp/skotiq_mosaic_test',
      ),
    );
    expect(find.text('Mosaic project not found'), findsOneWidget);
    expect(_backAction, findsOneWidget);

    await disposeScreen(tester);
  });
}
