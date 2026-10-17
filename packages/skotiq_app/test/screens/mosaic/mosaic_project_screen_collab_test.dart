// Widget tests for the collaborative surface on the Mosaic project review
// screen (`MosaicCollaborativeSection` + the per-panel claim/upload affordances
// on the grid).
//
// Pumps the REAL `MosaicProjectScreen` with explicit (temp) path builders,
// `databaseProvider` overridden to a seeded in-memory DB, and
// `constellationConfiguredProvider` forced true (a hub is signed in) — the real
// `collaborativeMosaicServiceProvider` resolves off that DB, so `canCollaborate`
// is true and the section renders exactly as in production. Each case seeds a
// different collaborative lifecycle and asserts the right action is offered:
//
//   * local-only project     → "Publish to hub" (and the section is present);
//   * published owner+assembling → "Assemble + publish";
//   * complete               → "Download finished mosaic";
//   * published + open panel  → a per-panel "Claim" button on the grid;
//   * published + claimed panel → a per-panel "Force release" recovery button.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  late SkotiqDatabase db;
  late MosaicProjectsDao projectsDao;
  late MosaicPanelsDao panelsDao;
  late IntegratedMastersDao mastersDao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    projectsDao = MosaicProjectsDao(db);
    panelsDao = MosaicPanelsDao(db);
    mastersDao = IntegratedMastersDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedProject({int cols = 2}) async {
    final projectId =
        await projectsDao.create(name: 'Veil', rows: 1, cols: cols);
    for (var i = 0; i < cols; i++) {
      await panelsDao.upsert(
        projectId: projectId,
        panelIndex: i,
        centerRa: 20.0 + i * 0.1,
        centerDec: 30.0,
      );
    }
    return projectId;
  }

  Future<void> pumpScreen(WidgetTester tester, int projectId) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // A hub is configured/signed-in so the collaborative section renders;
          // canCollaborate now gates on this signal, not just a wired service.
          constellationConfiguredProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: MosaicProjectScreen(
            projectId: projectId,
            artifactsBaseDir: '/tmp/mosaic',
          ),
        ),
      ),
    );
    // Let the controller's async load resolve (no pumpAndSettle — the busy
    // progress bar never idles in some states).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(microseconds: 1));
  }

  testWidgets('local-only project offers "Publish to hub"', (tester) async {
    final projectId = await seedProject();
    await pumpScreen(tester, projectId);

    expect(find.text('Collaborative mosaic'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Publish to hub'),
      findsOneWidget,
    );
    // Not published yet → no assemble / download affordance.
    expect(
      find.widgetWithText(SkotiqButton, 'Assemble + publish'),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  testWidgets('owner + assembling offers "Assemble + publish" (not Publish)',
      (tester) async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    await projectsDao.setCollabStatus(projectId, 'assembling');
    await pumpScreen(tester, projectId);

    expect(
      find.widgetWithText(SkotiqButton, 'Assemble + publish'),
      findsOneWidget,
    );
    // Already published → the publish CTA is gone.
    expect(
      find.widgetWithText(SkotiqButton, 'Publish to hub'),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  testWidgets('complete offers "Download finished mosaic"', (tester) async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    await projectsDao.setCollabStatus(projectId, 'complete');
    await pumpScreen(tester, projectId);

    expect(
      find.widgetWithText(SkotiqButton, 'Download finished mosaic'),
      findsOneWidget,
    );
    // A participant is never offered the owner-only assemble action.
    expect(
      find.widgetWithText(SkotiqButton, 'Assemble + publish'),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  testWidgets(
      'a published mosaic shows a per-panel Claim button on open panels',
      (tester) async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    await pumpScreen(tester, projectId);

    // Both panels are unclaimed → each tile offers a Claim button.
    expect(find.widgetWithText(SkotiqButton, 'Claim'), findsWidgets);
    await disposeScreen(tester);
  });

  testWidgets('an integrated, unuploaded panel shows a per-panel Upload button',
      (tester) async {
    final projectId = await seedProject(cols: 1);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    // Integrate the single panel (link a master) and claim it, so the only
    // collaborative affordance left for it is Upload.
    final masterId = await mastersDao.insertMaster(
      name: 'Panel 0',
      masterFitsPath: '/tmp/p0.fits',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );
    final panel = await panelsDao.getByIndex(projectId, 0);
    await panelsDao.setMaster(panel!.id!, masterId);
    await panelsDao.setClaim(
      panel.id!,
      claimToken: 'baton-0',
      rigId: 'rig-1',
      accountId: 'acct-1',
    );
    await pumpScreen(tester, projectId);

    expect(find.widgetWithText(SkotiqButton, 'Upload'), findsOneWidget);
    // Claimed → no Claim button for it.
    expect(find.widgetWithText(SkotiqButton, 'Claim'), findsNothing);
    // A claimed panel is evictable → the owner/admin recovery button is offered.
    expect(
      find.widgetWithText(SkotiqButton, 'Force release'),
      findsOneWidget,
    );
    await disposeScreen(tester);
  });

  testWidgets('the card says how many panels THIS rig is holding',
      (tester) async {
    // Deciding whether to claim more (or hand some back) needs the count of
    // panels you are committed to shooting; the card only ever reported how
    // many had been uploaded to the hub.
    final projectId = await seedProject(cols: 3);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final claimed = await panelsDao.getByIndex(projectId, 0);
    await panelsDao.setClaim(
      claimed!.id!,
      claimToken: 'baton-0',
      rigId: 'rig-1',
      accountId: 'acct-1',
    );
    await pumpScreen(tester, projectId);

    expect(find.textContaining('You hold 1 of 3 panels'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('an uploaded panel is no longer counted as held', (tester) async {
    // A delivered panel is not outstanding work: the hub refuses to release an
    // uploaded panel and never re-opens it, and the grid already hides Release
    // for it. Counting it as held told the operator they had panels to shoot
    // (or hand back) that they had in fact already finished.
    final projectId = await seedProject(cols: 3);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final masterId = await mastersDao.insertMaster(
      name: 'Panel 0',
      masterFitsPath: '/tmp/p0.fits',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );
    for (final index in [0, 1]) {
      final panel = await panelsDao.getByIndex(projectId, index);
      await panelsDao.setClaim(
        panel!.id!,
        claimToken: 'baton-$index',
        rigId: 'rig-1',
        accountId: 'acct-1',
      );
      // Panel 0 has already been delivered; panel 1 is still being shot.
      if (index == 0) await panelsDao.setUploaded(panel.id!, masterId);
    }
    await pumpScreen(tester, projectId);

    expect(find.textContaining('You hold 1 of 3 panels'), findsOneWidget);
    expect(find.textContaining('You hold 2 of 3 panels'), findsNothing);
    expect(find.textContaining('1 uploaded to the hub'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('an unclaimed (pending) panel offers no Force release button',
      (tester) async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    await pumpScreen(tester, projectId);

    // Pending panels are already free → nothing to force-release.
    expect(
      find.widgetWithText(SkotiqButton, 'Force release'),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  testWidgets('a panel this device holds a claim on offers a Release button',
      (tester) async {
    final projectId = await seedProject(cols: 1);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final panel = await panelsDao.getByIndex(projectId, 0);
    await panelsDao.setClaim(
      panel!.id!,
      claimToken: 'baton-0',
      rigId: 'rig-1',
      accountId: 'acct-1',
    );
    await pumpScreen(tester, projectId);

    // The holder hands their own claim back — without this the panel is locked
    // until the owner force-releases it or the hub TTL expires.
    expect(find.widgetWithText(SkotiqButton, 'Release'), findsOneWidget);
    // Eviction stays owner-only.
    expect(
      find.widgetWithText(SkotiqButton, 'Force release'),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  testWidgets('an unclaimed panel offers no Release button', (tester) async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    await pumpScreen(tester, projectId);

    // Nothing is held here, so there is nothing to give back.
    expect(find.widgetWithText(SkotiqButton, 'Release'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('a participant is not offered an unbounded "Claim all pending"',
      (tester) async {
    final projectId = await seedProject(cols: 6);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    await pumpScreen(tester, projectId);

    // One tap must not be able to lock every panel of someone else's mosaic.
    expect(
      find.widgetWithText(SkotiqButton, 'Claim all pending'),
      findsNothing,
    );
    // A bounded batch is still offered so a contributor can take real work.
    expect(find.widgetWithText(SkotiqButton, 'Claim 3 panels'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('the owner keeps "Claim all pending" on her own mosaic',
      (tester) async {
    final projectId = await seedProject(cols: 6);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    await pumpScreen(tester, projectId);

    expect(
      find.widgetWithText(SkotiqButton, 'Claim all pending'),
      findsOneWidget,
    );
    await disposeScreen(tester);
  });

  testWidgets('no configured hub hides the whole collaborative section',
      (tester) async {
    final projectId = await seedProject();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Signed out: canCollaborate is false, so the section is not rendered
          // and the buttons cannot be tapped-then-fail.
          constellationConfiguredProvider.overrideWith((ref) async => false),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: MosaicProjectScreen(
            projectId: projectId,
            artifactsBaseDir: '/tmp/mosaic',
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Collaborative mosaic'), findsNothing);
    expect(
      find.widgetWithText(SkotiqButton, 'Publish to hub'),
      findsNothing,
    );
    await disposeScreen(tester);
  });
}
