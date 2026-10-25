import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_route.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_app/screens/darkroom/targets/calibration_panel.dart';
import 'package:skotiq_app/screens/darkroom/targets/darkroom_targets_providers.dart';
import 'package:skotiq_app/screens/darkroom/targets/framing_check.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart'
    show subThumbnailProvider;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/pump_app_screen.dart' show TestBackendNotifier;
import 'owner_nights_fixture.dart';

/// The native side of the framing check: every light lands on the grid
/// except one late East sub, shifted far enough to cut the common area to
/// 62%.
class _Native {
  final requests = <Map<String, dynamic>>[];

  /// The basename of the shifted sub, or null for none.
  String? shifted;

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) async {
    requests.add(args);
    switch (args['op']) {
      case 'checkCalibration':
        return {};
      case 'registrationPreview':
        final lights = [
          for (final g in args['groups'] as List)
            for (final l in g['lights'] as List)
              (g['label'] as String, l as Map),
        ];
        final limiting = lights
            .where((l) => '${l.$2['path']}'.endsWith('$shifted'))
            .toList();
        final limited = shifted != null && limiting.isNotEmpty;
        return {
          'width': 4656,
          'height': 3520,
          'frames': [
            for (final (label, l) in lights)
              {
                'path': l['path'],
                'group': label,
                'side': l['side'],
                'corners': limiting.any((x) => x.$2['path'] == l['path'])
                    ? [
                        [1300, -400],
                        [5956, -400],
                        [5956, 3120],
                        [1300, 3120],
                      ]
                    : [
                        [2, 2],
                        [4654, 2],
                        [4654, 3518],
                        [2, 3518],
                      ],
                'overlap': .99,
                'rotationDeg': .1,
                'included': true,
              },
          ],
          'crop': limited ? [1300, 2, 4654, 3120] : [2, 2, 4654, 3518],
          'retainedArea': limited ? .62 : .997,
          'minRetainedArea': args['minRetainedArea'],
          'meetsMinimum':
              (limited ? .62 : .997) >= (args['minRetainedArea'] as num),
          'limiting': limited
              ? [
                  {
                    'path': limiting.single.$2['path'],
                    'group': limiting.single.$1,
                    'retainedWithout': .997,
                  },
                ]
              : [],
        };
    }
    throw StateError('Native build must not run: ${args['op']}');
  }
}

class _Service extends DarkroomBuildService {
  _Service(SkotiqDatabase db, _Native native)
      : super(
          operation: native.call,
          library: CalibrationLibraryService(
            db: db,
            flatLibraryDao: FlatLibraryDao(db),
            tagsDao: CalibrationTagsDao(db),
          ),
          masters: IntegratedMastersDao(db),
          readHeader: (_) async => {
            'INSTRUME': 'ZWO ASI294MM Pro',
            'TELESCOP': '10" Newt',
            'NAXIS1': '4656',
            'NAXIS2': '3520',
          },
        );

  @override
  Future<List<DarkroomBuildGroup>> prepare(List<DbCapturedImage> frames) async {
    final groups = await super.prepare(frames);
    for (final g in groups) {
      if (g.filter == 'L' || g.filter == 'B') {
        g.calibration['flat'] = '/flats/${g.filter}_master.fits';
      }
    }
    return groups;
  }
}

/// Records the build the framing check accepts instead of running it.
class _Jobs extends DarkroomBuildJobs {
  final accepted = <Directory?>[];

  @override
  Future<void> accept([Directory? directory]) async {
    accepted.add(directory);
  }
}

/// Held builds a test can set directly.
class _Held extends DarkroomHeldBuilds {
  void put(List<DarkroomBuildJob> jobs) => state = jobs;
}

CalibrationMatch _match(
  CalibrationMasterType type,
  int id,
  String path, {
  double? exposure,
  int? frames,
  String? filter,
}) =>
    CalibrationMatch(
      score: 1,
      record: CalibrationMasterRecord(
        type: type,
        id: id,
        filePath: path,
        isMaster: true,
        exposureSeconds: exposure,
        frameCount: frames,
        filter: filter,
        createdAt: DateTime(2026, 10, 23, 9),
      ),
    );

/// The owner's library: darks and bias for every filter, flats for L and B.
List<DarkroomFilterCalibration> _library() => [
      for (final f in ['L', 'R', 'G', 'B'])
        DarkroomFilterCalibration(
          filter: f,
          exposureSeconds: f == 'L' ? 90 : 120,
          match: CalibrationMatchSet(
            context: LightFrameContext(
              gain: 76,
              offset: 15,
              exposureSeconds: f == 'L' ? 90 : 120,
              filter: f,
            ),
            dark: _match(
              CalibrationMasterType.dark,
              1,
              '/cal/dark_${f == 'L' ? 90 : 120}.fits',
              exposure: f == 'L' ? 90 : 120,
              frames: 20,
            ),
            bias: _match(
              CalibrationMasterType.bias,
              2,
              '/cal/bias.fits',
              frames: 50,
            ),
            flat: f == 'L' || f == 'B'
                ? _match(
                    CalibrationMasterType.flat,
                    3,
                    '/flats/${f}_master.fits',
                    filter: f,
                  )
                : null,
          ),
        ),
    ];

class _Harness {
  _Harness(this.owner, this.native, this.jobs, this.router, this.container);
  final OwnerNights owner;
  final _Native native;
  final _Jobs jobs;
  final GoRouter router;
  final ProviderContainer container;

  String get location => router.routeInformationProvider.value.uri.toString();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  String initial = '/darkroom',
  Size size = const Size(1800, 1000),
  List<Override> overrides = const [],
  String? shifted,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final owner = await seedOwnerNights();
  addTearDown(owner.db.close);
  final native = _Native()..shifted = shifted;
  final jobs = _Jobs();
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/darkroom',
        builder: (context, state) =>
            DarkroomScreen.route(DarkroomRoute.fromUri(state.uri)),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const Text('Settings'),
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      backendProvider
          .overrideWith((ref) => TestBackendNotifier(ref, mockBackend())),
      databaseProvider.overrideWithValue(owner.db),
      darkroomBuildServiceProvider
          .overrideWithValue(_Service(owner.db, native)),
      darkroomBuildJobsProvider.overrideWith(() => jobs),
      darkroomTargetCalibrationProvider
          .overrideWith((ref, key) async => _library()),
      darkroomMastersRootProvider
          .overrideWith((ref) async => Directory('/data/Masters')),
      subThumbnailProvider.overrideWith(
        (ref, id) => Future<Uint8List>.error(StateError('no thumbnail')),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await _settle(tester);
  return _Harness(owner, native, jobs, router, container);
}

/// Lets the database reads and the native fake answer.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('the Targets tab lists the target and what it needs', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Targets'), findsOneWidget);
    expect(find.byKey(const ValueKey('darkroom_target_row_NGC 891')),
        findsOneWidget);
    expect(find.text('3 new nights to build'), findsOneWidget);
    expect(find.textContaining('4 nights · LRGB'), findsOneWidget);
    expect(
      find.text('3 new nights since your last masters, ready to fold in.'),
      findsOneWidget,
    );
    expect(find.text('NGC 891'), findsWidgets);
    expect(
        find.textContaining('GALAXY · AND · RA 02h 22m 33s'), findsOneWidget);
    expect(find.text('Open the color image'), findsOneWidget);
  });

  testWidgets('channel tiles carry hours and flat status from the library', (
    tester,
  ) async {
    await _pump(tester);

    for (final f in ['L', 'R', 'G', 'B']) {
      expect(find.byKey(ValueKey('darkroom_channel_$f')), findsOneWidget);
    }
    expect(find.text('Flat ready'), findsNWidgets(2));
    expect(find.text('No flat'), findsNWidgets(2));
  });

  testWidgets('the nights strip draws every night with its axis and notes', (
    tester,
  ) async {
    await _pump(tester);

    for (final label in [
      'Oct 23 to 24',
      'Oct 22 to 23',
      'Oct 21 to 22',
      'Oct 20 to 21',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('in masters'), findsOneWidget);
    expect(find.text('Flip at 01:36'), findsNWidgets(2));
    expect(find.text('Local time'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Rejected or off target'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Oct 23 to 24, ')),
    );
    expect(semantics.label, contains('5 off target'));
    expect(semantics.label, contains('flip at 01:36'));
    expect(semantics.label, contains('no stars at 03:28'));
  });

  testWidgets('a missing flat is fixed inline with another filter\'s flat', (
    tester,
  ) async {
    final h = await _pump(tester);

    expect(find.text('Flat none', findRichText: true), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('darkroom_use_flat_R_L')));
    await _settle(tester);

    expect(
      h.container.read(darkroomFlatChoicesProvider('NGC 891')),
      {'R': '/flats/L_master.fits'},
    );
    expect(find.text('Flat L_master.fits', findRichText: true), findsOneWidget);
    expect(find.text('Flat ready'), findsNWidgets(3));
  });

  testWidgets('the last masters panel lists each filter and the color image', (
    tester,
  ) async {
    await _pump(tester);

    for (final name in [
      'L master',
      'R master',
      'G master',
      'B master',
      'Color image',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('Oct 21 · 1 night'), findsOneWidget);
  });

  testWidgets('tabs are locations', (tester) async {
    final h = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('darkroom_tab_calibration')));
    await _settle(tester);
    expect(h.location, '/darkroom?tab=calibration');
    expect(
      tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar)).selectedIndex,
      1,
    );

    await tester.tap(find.byKey(const ValueKey('darkroom_tab_targets')));
    await _settle(tester);
    expect(h.location, '/darkroom?tab=targets');
    expect(find.text('3 new nights to build'), findsOneWidget);
  });

  testWidgets('Build masters opens the framing check inside the Darkroom', (
    tester,
  ) async {
    final h = await _pump(tester, shifted: 'NGC0891_B_0124.fits');

    await tester.tap(find.byKey(const ValueKey('darkroom_hero_build')));
    await _settle(tester);

    expect(h.location, '/darkroom?tab=targets&target=NGC+891&view=framing');
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Framing check'), findsOneWidget);
    // The rejected subs never reach the plan.
    final preview =
        h.native.requests.lastWhere((r) => r['op'] == 'registrationPreview');
    final paths = [
      for (final g in preview['groups'] as List)
        for (final l in g['lights'] as List) l['path'],
    ];
    expect(paths, hasLength(h.jobs.state!.plan!.lights.length));
    expect(paths.length,
        lessThan((await h.owner.db.imagesDao.getAllImages()).length));

    expect(find.byKey(const ValueKey('darkroom_field_kept')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('darkroom_field_kept')))
          .data,
      '62.0',
    );
    expect(find.text('One sub is holding it back'), findsOneWidget);
    expect(find.text('NGC0891_B_0124'), findsOneWidget);
    expect(find.textContaining('below the 80% minimum'), findsWidgets);
    final build = tester.widget<SkotiqButton>(
      find.byKey(const ValueKey('darkroom_framing_build')),
    );
    expect(build.onPressed, isNull);
  });

  testWidgets('leave a sub out, put it back, then build in the background', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      initial: '/darkroom?tab=targets&target=NGC+891&view=framing',
      shifted: 'NGC0891_B_0124.fits',
    );
    expect(find.text('One sub is holding it back'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('darkroom_leave_out')));
    await _settle(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('darkroom_field_kept')))
          .data,
      '99.7',
    );
    expect(find.text('NGC0891_B_0124 left out'), findsOneWidget);
    expect(
      h.jobs.state!.plan!.lights.any(
        (l) => '${l['path']}'.endsWith('NGC0891_B_0124.fits'),
      ),
      isFalse,
    );
    final excluded = h.jobs.state!.plan!.toJson()['excluded'] as List;
    expect(
      excluded.any((e) => e['reason'] == darkroomLeftOutReason),
      isTrue,
    );

    await tester.tap(find.text('Put it back'));
    await _settle(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('darkroom_field_kept')))
          .data,
      '62.0',
    );
    // Putting it back reuses its footprint: nothing is registered again.
    final last =
        h.native.requests.lastWhere((r) => r['op'] == 'registrationPreview');
    expect(last['gridSize'], [4656, 3520]);

    await tester.tap(find.byKey(const ValueKey('darkroom_leave_out')));
    await _settle(tester);

    // R and G have no flat: Build waits for that decision.
    expect(
      tester
          .widget<SkotiqButton>(
              find.byKey(const ValueKey('darkroom_framing_build')))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Build R, G without flats'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('darkroom_without_flats')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('darkroom_framing_build')));
    await _settle(tester);

    expect(h.jobs.accepted, hasLength(1));
    expect(h.jobs.accepted.single!.path, '/data/Masters/NGC_891');
    expect(h.location, '/darkroom?tab=targets&target=NGC+891');
  });

  testWidgets('a night can be left out of the build, except the reference\'s',
      (tester) async {
    final h = await _pump(
      tester,
      initial: '/darkroom?tab=targets&target=NGC+891&view=framing',
    );
    await _settle(tester);
    final reference = h.jobs.state!.plan!.referencePath;
    final before = h.jobs.state!.plan!.lights.length;

    final nights = [
      for (final key in [
        '2026-10-20',
        '2026-10-21',
        '2026-10-22',
        '2026-10-23'
      ])
        find.byKey(ValueKey('darkroom_night_$key')),
    ];
    for (final n in nights) {
      expect(n, findsOneWidget);
    }
    final referenceNight = observingNight(
      (await h.owner.db.imagesDao.getAllImages())
          .firstWhere((f) => f.filePath == reference)
          .capturedAt,
    );
    final other = ['2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23']
        .firstWhere((k) => k != referenceNight);
    await tester.ensureVisible(find.byKey(ValueKey('darkroom_night_$other')));
    await tester.tap(find.byKey(ValueKey('darkroom_night_$other')));
    await _settle(tester);
    expect(h.jobs.state!.plan!.lights.length, lessThan(before));
    expect(
      h.container
          .read(darkroomFramingSessionProvider('NGC 891'))!
          .leftOut
          .values
          .toSet(),
      {darkroomNightLeftOutReason},
    );
  });

  testWidgets(
      'a build held by the night-end run is reviewed, not checked again',
      (tester) async {
    final held = _Held();
    final h = await _pump(
      tester,
      initial: '/darkroom?tab=targets&target=NGC+891&view=framing',
      overrides: [darkroomHeldBuildsProvider.overrideWith(() => held)],
    );
    final checked = h.jobs.state!;
    expect(checked.stage, DarkroomJobStage.awaitingReview);
    h.router.go('/darkroom?tab=targets&target=NGC+891');
    await _settle(tester);
    h.jobs.state = null;
    held.put([
      DarkroomBuildJob(
        target: 'NGC 891',
        unattended: true,
        nightRunId: 'night-2026-10-23',
        stage: DarkroomJobStage.awaitingReview,
        message: checked.message,
        startedAt: checked.startedAt,
        plan: checked.plan,
        preview: checked.preview,
        directory: '/data/Masters/NGC_891',
      ),
    ]);
    final previews =
        h.native.requests.where((r) => r['op'] == 'registrationPreview').length;

    h.router.go('/darkroom?tab=targets&target=NGC+891&view=framing');
    await _settle(tester);

    // The held build became the current one; nothing was registered again.
    expect(h.jobs.state?.nightRunId, 'night-2026-10-23');
    expect(h.jobs.state?.stage, DarkroomJobStage.awaitingReview);
    expect(held.state, isEmpty);
    expect(
      h.native.requests.where((r) => r['op'] == 'registrationPreview').length,
      previews,
    );
    expect(find.byKey(const ValueKey('darkroom_field_kept')), findsOneWidget);
  });

  testWidgets('checking another target holds the build waiting for review', (
    tester,
  ) async {
    final h = await _pump(tester);
    final waiting = DarkroomBuildJob(
      target: 'M 81',
      unattended: true,
      nightRunId: 'night-2026-10-23',
      stage: DarkroomJobStage.awaitingReview,
      message: 'Waiting for review',
      startedAt: DateTime(2026, 10, 24, 6),
    );
    h.jobs.state = waiting;

    h.router.go('/darkroom?tab=targets&target=NGC+891&view=framing');
    await _settle(tester);

    expect(h.jobs.state?.target, 'NGC 891');
    final parked = h.container.read(darkroomHeldBuildsProvider);
    expect(parked.map((j) => j.target), ['M 81']);
    expect(parked.single.nightRunId, 'night-2026-10-23');
  });

  testWidgets('while another target builds, the check waits instead', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.jobs.state = DarkroomBuildJob(
      target: 'M 81',
      stage: DarkroomJobStage.building,
      message: 'Building L (1 of 4)',
      startedAt: DateTime(2026, 10, 25, 2),
      overallDone: 10,
      overallTotal: 200,
    );
    await _settle(tester);
    final build = tester.widget<SkotiqButton>(
      find.byKey(const ValueKey('darkroom_hero_build')),
    );
    expect(build.onPressed, isNull);
    expect(find.text('Building M 81 10/200'), findsOneWidget);

    h.router.go('/darkroom?tab=targets&target=NGC+891&view=framing');
    await _settle(tester);
    expect(find.text('A build for M 81 is running'), findsOneWidget);
    expect(
      h.native.requests.where((r) => r['op'] == 'registrationPreview'),
      isEmpty,
    );
  });

  testWidgets('the detail fits at 1280 wide without overflow', (tester) async {
    await _pump(tester, size: const Size(1190, 800));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('darkroom_channel_L')), findsOneWidget);
  });

  testWidgets('the framing check fits at 1280 wide without overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1190, 760),
      initial: '/darkroom?tab=targets&target=NGC+891&view=framing',
      shifted: 'NGC0891_B_0124.fits',
    );
    expect(find.text('One sub is holding it back'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('darkroom_framing_build')), findsOneWidget);
  });

  testWidgets('a flat chosen from a file is shown by name', (tester) async {
    final h = await _pump(
      tester,
      overrides: [
        darkroomFlatPickerProvider.overrideWithValue(
          (filter) async => '/flats/G_from_disk.fits',
        ),
      ],
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('darkroom_choose_flat_G')),
    );
    await tester.tap(find.byKey(const ValueKey('darkroom_choose_flat_G')));
    await _settle(tester);
    expect(
      h.container.read(darkroomFlatChoicesProvider('NGC 891'))['G'],
      '/flats/G_from_disk.fits',
    );
    expect(
      find.text('Flat G_from_disk.fits', findRichText: true),
      findsOneWidget,
    );
  });
}
