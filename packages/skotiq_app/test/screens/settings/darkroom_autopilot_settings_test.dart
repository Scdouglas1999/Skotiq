// The dawn Darkroom autopilot's settings surface.
//
// `darkroom.auto_draft` shipped as a raw `app_settings` row with no widget, no
// API and absent-means-on, and Settings said nothing about the Darkroom at all
// — "darkroom", "draft", "recipe" and "auto draft" each returned "No settings
// match your search". A single D1 night on that unmentioned default wrote 4
// recipes, 4 draft JPEGs, 4 sidecars, a night report, 9 delivered files and a
// morning notification. These tests pin the surface that now answers for it:
// where it lives, what it says, and that the switch writes the row the pass
// reads.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/session_review/auto_integration_service.dart';
import 'package:skotiq_app/screens/settings/delivery_settings.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/darkroom_autopilot_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

void main() {
  Future<List<SettingsGroupDef>> catalog(WidgetTester tester) async {
    late List<SettingsGroupDef> groups;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            groups = buildSettingsGroups(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return groups;
  }

  testWidgets('the dawn autopilot sits beside Delivery in Automation', (
    tester,
  ) async {
    final groups = await catalog(tester);
    final owning = groups.firstWhere(
      (g) => g.sections.any((s) => s.key == 'darkroom'),
      orElse: () => throw StateError(
        'no settings group renders the darkroom section: '
        '${groups.map((g) => g.title).toList()}',
      ),
    );
    expect(owning.title, 'Automation & Safety');

    // Adjacent, not merely co-grouped: the pass composes what Delivery
    // carries, and a reader who finds one has found the other.
    final keys = owning.sections.map((s) => s.key).toList();
    expect(
      (keys.indexOf('delivery') - keys.indexOf('darkroom')).abs(),
      1,
      reason: 'order was $keys',
    );
  });

  test('the locale-independent group lookup agrees with the catalog', () {
    // `groupTitleForKey` reads `_structuralGroups`, a separate list from the
    // one `buildSettingsGroups` builds; a section added to only one of them
    // has a sidebar entry and no breadcrumb, or the reverse.
    expect(groupTitleForKey('darkroom'), 'Automation & Safety');
    expect(resolveSectionKey('darkroom'), 'darkroom');
  });

  testWidgets('the page names the whole chain, not just the draft', (
    tester,
  ) async {
    final db = mockDatabase();
    addTearDown(db.close);
    await pumpAppScreen(
      tester,
      const DarkroomAutopilotSettings(),
      database: db,
    );

    // The row that governs it.
    expect(find.text('Draft, deliver and report at dawn'), findsOneWidget);
    // Every link of the chain is named in the copy — the defect being fixed is
    // a switch that described half of what it does.
    final subtitle = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');
    for (final claim in [
      'first-draft',
      'draft render',
      'night report',
      'delivery destination',
      'notification',
    ]) {
      expect(subtitle.toLowerCase(), contains(claim.toLowerCase()),
          reason: '"$claim" is part of what this setting governs');
    }

    // And the neighbours that can silence it, with the one that can silence it
    // completely stating its own live state.
    expect(
      find.text('Auto-integrate has to be on for any of this to run'),
      findsOneWidget,
    );
    expect(
      find.text('The morning message rides the sequence-complete alerts'),
      findsOneWidget,
    );
    expect(
      find.textContaining('It is currently off.'),
      findsOneWidget,
      reason: 'the dependency is only useful beside what it currently says',
    );
  });

  // "What can silence it" answered for one of its three dependencies and
  // described the other two abstractly: the Delivery note never said how many
  // destinations this rig has — nor that the one it had could not be written
  // to — and the Notifications note never said whether either switch was on.
  // On the one page whose job is to say what will silence tonight's pass, two
  // of the three notes were unanswered questions.
  group('every dependency states its own live value', () {
    List<Override> deliveryOverrides({bool folderExists = true}) => [
          secretsStoreProvider.overrideWithValue(
            SecretsStore(InMemorySecureKeyValueStore()),
          ),
          watchedFolderExistsProvider.overrideWithValue(
            (_) async => folderExists,
          ),
        ];

    Future<void> seedDestination(SkotiqDatabase db, String name) async {
      await DeliveryTargetsDao(db).create(
        name: name,
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas-that-is-not-mounted/drop"}',
        content: const {ArtifactContent.linearMasters},
        enabled: true,
      );
    }

    String notesOf(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');

    testWidgets('a destination whose folder is not there is counted and named',
        (tester) async {
      final db = mockDatabase();
      addTearDown(db.close);
      await seedDestination(db, 'd1-drop');
      await pumpAppScreen(
        tester,
        const DarkroomAutopilotSettings(),
        database: db,
        extraOverrides: deliveryOverrides(folderExists: false),
      );
      await tester.pumpAndSettle();

      final notes = notesOf(tester);
      expect(
        notes,
        contains('1 destination is configured'),
        reason: 'the count is the first thing the note cannot answer without',
      );
      expect(notes, contains('cannot be delivered to as it stands'));
      // Both notification gates default on, and the note says so rather than
      // describing what "off" would do.
      expect(
          notes,
          contains('Notifications and the sequence-complete alert '
              'are both on'));
    });

    testWidgets('a rig with no destinations says so, and an off gate is named',
        (tester) async {
      final db = mockDatabase();
      addTearDown(db.close);
      await SettingsDao(db).setSetting('notifications_enabled', 'false');
      await pumpAppScreen(
        tester,
        const DarkroomAutopilotSettings(),
        database: db,
        extraOverrides: deliveryOverrides(),
      );
      await tester.pumpAndSettle();

      final notes = notesOf(tester);
      expect(notes, contains('No destination is configured here'));
      expect(notes, contains('Notifications are currently off'));
    });

    testWidgets('two destinations, one blocked, are counted as two', (
      tester,
    ) async {
      final db = mockDatabase();
      addTearDown(db.close);
      await seedDestination(db, 'd1-drop');
      await DeliveryTargetsDao(db).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: const {ArtifactContent.draftRender},
        enabled: true,
      );
      await pumpAppScreen(
        tester,
        const DarkroomAutopilotSettings(),
        database: db,
        extraOverrides: deliveryOverrides(folderExists: false),
      );
      await tester.pumpAndSettle();

      expect(
        notesOf(tester),
        contains('2 destinations are configured and 1 of them cannot be '
            'delivered to'),
      );
    });
  });

  // D2-4. A fresh install drew this switch [ON] one row above "Auto-integrate
  // has to be on for any of this to run ... It is currently off" — a headline
  // feature reading as armed on a rig where its own page says the pass cannot
  // run. Absent now follows the prerequisite, so the switch states what the
  // pass would actually do.
  testWidgets('a fresh install shows the switch off, with its reason beside it',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final handle = await pumpAppScreen(
      tester,
      const DarkroomAutopilotSettings(),
      database: db,
    );
    await tester.pumpAndSettle();

    expect(
      await SettingsDao(db).getSetting(kDarkroomAutoDraftSettingKey),
      isNull,
      reason: 'the case is a row that was never written',
    );
    expect(
      await SettingsDao(db).getSetting(kAutoIntegrateSettingKey),
      isNull,
      reason: 'and a prerequisite nobody has opted into',
    );
    final control = tester.widget<SkotiqSwitch>(
      find.byKey(const ValueKey('darkroom-auto-draft-switch')),
    );
    expect(control.value, isFalse);
    expect(
      handle.container.read(darkroomAutoDraftEnabledProvider).valueOrNull,
      isFalse,
    );
  });

  testWidgets('an untouched switch is on once the prerequisite is', (
    tester,
  ) async {
    // The other half of the same rule: a rig that integrates all night and
    // then declines to draft is the surprising behaviour, so the absent row
    // answers ON the moment there is something for it to act on.
    final db = mockDatabase();
    addTearDown(db.close);
    await SettingsDao(db).setSetting(kAutoIntegrateSettingKey, 'true');
    await pumpAppScreen(
      tester,
      const DarkroomAutopilotSettings(),
      database: db,
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SkotiqSwitch>(
            find.byKey(const ValueKey('darkroom-auto-draft-switch')),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('turning it off writes the value the pass reads', (
    tester,
  ) async {
    final db = mockDatabase();
    addTearDown(db.close);
    // Started from the armed state, which is where a rig that has opted into
    // automatic integration begins.
    await SettingsDao(db).setSetting(kAutoIntegrateSettingKey, 'true');
    await pumpAppScreen(
      tester,
      const DarkroomAutopilotSettings(),
      database: db,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('darkroom-auto-draft-switch')),
    );
    await tester.pumpAndSettle();

    // `_runDarkroom` skips only on the literal string 'false'.
    expect(
      await SettingsDao(db).getSetting(kDarkroomAutoDraftSettingKey),
      'false',
    );
    expect(
      tester
          .widget<SkotiqSwitch>(
            find.byKey(const ValueKey('darkroom-auto-draft-switch')),
          )
          .value,
      isFalse,
    );

    await tester.tap(
      find.byKey(const ValueKey('darkroom-auto-draft-switch')),
    );
    await tester.pumpAndSettle();
    expect(
      await SettingsDao(db).getSetting(kDarkroomAutoDraftSettingKey),
      'true',
    );
  });

  // The gate is the client ROLE, not the live connection — the same gate
  // Delivery and the Darkroom editor read. `darkroom.auto_draft` is a row in
  // whichever profile database this process opened, and the dawn pass reads
  // the one on the machine that integrated the masters.
  group('the dawn pass belongs to the machine that owns the masters', () {
    Future<void> pumpAs(
      WidgetTester tester, {
      required bool launchedAsClient,
      required bool connected,
      required SkotiqDatabase db,
    }) async {
      await pumpAppScreen(
        tester,
        const DarkroomAutopilotSettings(),
        database: db,
        extraOverrides: [
          remoteClientLaunchProvider.overrideWithValue(launchedAsClient),
          isRemoteModeProvider.overrideWithValue(connected),
        ],
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a connected client is told where the switch lives', (
      tester,
    ) async {
      final db = mockDatabase();
      addTearDown(db.close);
      await pumpAs(
        tester,
        launchedAsClient: false,
        connected: true,
        db: db,
      );

      expect(
        find.text('The dawn pass runs on the imaging host'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('darkroom-auto-draft-switch')),
        findsNothing,
      );
    });

    testWidgets(
      'a client that has not reached its rig yet is still that rig\'s client',
      (tester) async {
        // The launch flags said `--remote-host`; the handshake has not landed
        // (or it has dropped), so the connection-shaped gate reads false. On
        // that gate the page offered a live switch, and one click wrote
        // `darkroom.auto_draft=false` here while the rig kept drafting,
        // delivering and notifying at dawn.
        final db = mockDatabase();
        addTearDown(db.close);
        await pumpAs(
          tester,
          launchedAsClient: true,
          connected: false,
          db: db,
        );

        expect(
          find.text('The dawn pass runs on the imaging host'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('darkroom-auto-draft-switch')),
          findsNothing,
          reason: 'a switch here writes a row no dawn job will ever read',
        );
        expect(
          await SettingsDao(db).getSetting(kDarkroomAutoDraftSettingKey),
          isNull,
        );
      },
    );

    testWidgets('a host launch keeps its own switch', (tester) async {
      final db = mockDatabase();
      addTearDown(db.close);
      await pumpAs(
        tester,
        launchedAsClient: false,
        connected: false,
        db: db,
      );

      expect(
        find.text('The dawn pass runs on the imaging host'),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('darkroom-auto-draft-switch')),
        findsOneWidget,
      );
    });
  });

  testWidgets('the dependency row carries the page\'s own density', (
    tester,
  ) async {
    // Hardcoded `isMobile: false` put desktop padding, icon size and title
    // ramp on one row inside a phone-width section whose siblings were at
    // phone density.
    final db = mockDatabase();
    addTearDown(db.close);
    await pumpAppScreen(
      tester,
      const DarkroomAutopilotSettings(isMobile: true),
      database: db,
      size: const Size(430, 900),
    );
    await tester.pumpAndSettle();

    bool densityOf(String title) => tester
        .widgetList<SettingRow>(find.byType(SettingRow))
        .firstWhere((row) => row.title == title)
        .isMobile;

    expect(densityOf('Auto-integrate has to be on for any of this to run'),
        isTrue);
    expect(
      densityOf('Delivery destinations decide what leaves the rig'),
      isTrue,
      reason: 'the sibling it is misaligned against',
    );
  });

  testWidgets('the dependency row states its neighbour\'s state once', (
    tester,
  ) async {
    // `SettingRow` merges its title, subtitle and trailing into one node, so
    // the colour-coded echo beside the sentence was read out a second time,
    // as a bare "off" with nothing to bind it to.
    final db = mockDatabase();
    addTearDown(db.close);
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const DarkroomAutopilotSettings(),
      database: db,
    );
    await tester.pumpAndSettle();

    final label = tester
        .getSemantics(
          find.text('Auto-integrate has to be on for any of this to run'),
        )
        .label
        .trim();

    expect(label, contains('It is currently off.'));
    expect(
      label,
      contains('Settings › Image grading › Post-session integration.'),
      reason: 'the sentence carries the state; the visual echo must not '
          'publish a second, unbound copy of it',
    );
    // One "off" in the whole node: the sentence's, not the echo's as well.
    expect('off '.allMatches('$label ').length, 1, reason: label);
    // The echo is still on screen for the eye scanning the column.
    expect(find.text('off'), findsOneWidget);
    semantics.dispose();
  });

  group('each dependency row opens the page it names', () {
    // The three rows under "What can silence it" named the setting that could
    // silence tonight's pass and then ended in a bare path — "Settings ›
    // Delivery." — with no control beside them. A walk of the page found ONE
    // interactive node on it, the switch; acting on any of the three meant
    // leaving and hunting for it.
    const links = [
      (
        'Auto-integrate has to be on for any of this to run',
        'Image grading',
        'image-grading'
      ),
      (
        'Delivery destinations decide what leaves the rig',
        'Delivery',
        'delivery'
      ),
      (
        'The morning message rides the sequence-complete alerts',
        'Notifications',
        'notifications'
      ),
    ];

    Future<GoRouter> pumpInRouter(WidgetTester tester) async {
      final db = mockDatabase();
      addTearDown(db.close);
      // Tall enough for the whole page: a control below the fold is not the
      // subject of this test.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 1400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (_, __) => const Scaffold(
              body: DarkroomAutopilotSettings(),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('the row carries a control named for its destination', (
      tester,
    ) async {
      await pumpInRouter(tester);
      for (final (_, label, _) in links) {
        expect(
          find.widgetWithText(SkotiqButton, label),
          findsOneWidget,
          reason: '"$label" is the page this row sends the operator to',
        );
      }
    });

    for (final (title, label, sectionKey) in links) {
      testWidgets('"$label" goes to the $sectionKey section', (tester) async {
        SettingsSectionRequest.reset();
        addTearDown(SettingsSectionRequest.reset);
        final router = await pumpInRouter(tester);

        final control = find.widgetWithText(SkotiqButton, label);
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        await tester.tap(control);
        await tester.pumpAndSettle();

        // Both halves of the link, because a repeat press from inside Settings
        // carries an identical route and only the raised request moves the
        // pane.
        expect(SettingsSectionRequest.section, sectionKey);
        expect(
          router.routerDelegate.currentConfiguration.uri.toString(),
          '/settings?section=$sectionKey',
          reason: 'the row titled "$title" names that section',
        );
      });
    }
  });
}
