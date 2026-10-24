import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/build_masters/build_job_banner.dart';
import 'package:skotiq_app/screens/darkroom/build_masters_dialog.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart'
    show subThumbnailProvider;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The owner's data: four nights of L, R, G and B, with flats for L and B
/// only. The native side answers the framing check with one late R frame
/// shifted far enough to limit the crop.
class _Native {
  final requests = <Map<String, dynamic>>[];
  double retained = .62;

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
        final shifted = lights
            .where((l) => '${l.$2['path']}'.endsWith('R_n4_2.fits'))
            .map((l) => l.$2['path'])
            .toSet();
        final frames = [
          for (final (label, l) in lights)
            {
              'path': l['path'],
              'group': label,
              'side': l['side'],
              'corners': shifted.contains(l['path'])
                  ? [
                      [1400, 1100],
                      [7600, 1100],
                      [7600, 5300],
                      [1400, 5300],
                    ]
                  : [
                      [2, 2],
                      [6243, 2],
                      [6243, 4171],
                      [2, 4171],
                    ],
              'overlap': shifted.contains(l['path']) ? .63 : .998,
              'rotationDeg': 0.1,
              'included': true,
            },
        ];
        final limited = shifted.isNotEmpty && retained < .8;
        return {
          'width': 6248,
          'height': 4176,
          'frames': frames,
          'crop': limited ? [1400, 1100, 6244, 4172] : [2, 2, 6244, 4172],
          'retainedArea': limited ? retained : .997,
          'minRetainedArea': args['minRetainedArea'],
          'meetsMinimum':
              (limited ? retained : .997) >= (args['minRetainedArea'] as num),
          'limiting': limited
              ? [
                  {
                    'path': shifted.single,
                    'group': 'Night of 2026-10-24 · R',
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
            'INSTRUME': 'ZWO ASI2600MM Pro',
            'TELESCOP': 'RedCat 51',
            'NAXIS1': '6248',
            'NAXIS2': '4176',
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

class _PresetJobs extends DarkroomBuildJobs {
  _PresetJobs(this.job);
  final DarkroomBuildJob job;
  @override
  DarkroomBuildJob? build() => job;
}

Future<SkotiqDatabase> _ownerData() async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final target = await db.targetsDao.createTarget(
    TargetsCompanion.insert(name: 'NGC891', ra: 2.3, dec: 42.3),
  );
  final evenings = [
    DateTime(2026, 10, 18, 21),
    DateTime(2026, 10, 20, 21),
    DateTime(2026, 10, 22, 21),
    DateTime(2026, 10, 23, 21),
  ];
  for (var n = 0; n < evenings.length; n++) {
    for (final f in ['L', 'R', 'G', 'B']) {
      for (var i = 0; i < 3; i++) {
        // Frames run past midnight; the cooler drifts by a degree.
        final at =
            evenings[n].add(Duration(minutes: 70 * i + 40 * 'LRGB'.indexOf(f)));
        await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            targetId: Value(target),
            filePath: '/data/NGC891/${f}_n${n + 1}_$i.fits',
            fileName: '${f}_n${n + 1}_$i.fits',
            exposureDuration: 120,
            filter: Value(f),
            gain: const Value(100),
            offset: const Value(50),
            sensorTemp: Value(-10 + i * .5),
            pierSide: Value(i == 2 ? 'East' : 'West'),
            capturedAt: at,
          ),
        );
      }
    }
  }
  return db;
}

Widget _app(List<Override> overrides, Widget child) => ProviderScope(
      overrides: [
        subThumbnailProvider.overrideWith(
          (ref, id) => Future<Uint8List>.error(StateError('no thumbnail')),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'setup groups by night, requires a decision on missing flats, then checks framing and offers a one-click exclude',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = await _ownerData();
      addTearDown(db.close);
      final native = _Native();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          darkroomBuildServiceProvider.overrideWithValue(_Service(db, native)),
          subThumbnailProvider.overrideWith(
            (ref, id) => Future<Uint8List>.error(StateError('no thumbnail')),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: BuildMastersDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final check = find.widgetWithText(SkotiqButton, 'Check framing');
      expect(tester.widget<SkotiqButton>(check).onPressed, isNull);

      await tester.tap(find.byType(SkotiqDropdown).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('NGC891 · 48 captures').last);
      await tester.pumpAndSettle();
      // Four observing nights, not one per calendar date.
      expect(find.textContaining('Night of 2026-10-18 · 12 of 12 frames'),
          findsOneWidget);
      expect(find.textContaining('Night of 2026-10-23 · 12 of 12 frames'),
          findsOneWidget);
      expect(find.textContaining('Night of 2026-10-19'), findsNothing);

      await tester.tap(find.text('Prepare calibration'));
      await tester.pumpAndSettle();
      // One group per night and filter despite cooler drift and midnight.
      expect(find.textContaining('L · 4 groups · 12 frames'), findsOneWidget);
      expect(
        find.textContaining('Flats are available for B, L, but not for G, R.'),
        findsOneWidget,
      );

      Future<void> tapText(String text) async {
        final target = find.text(text);
        await tester.scrollUntilVisible(
          target,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tapText(
          'I reviewed the calibration choices and any missing masters.');
      expect(
        tester.widget<SkotiqButton>(check).onPressed,
        isNull,
        reason: 'R and G still need a decision about flats',
      );
      await tapText('Build G without flats');
      await tapText('Build R without flats');
      expect(tester.widget<SkotiqButton>(check).onPressed, isNotNull);

      await tester.tap(check);
      await tester.pumpAndSettle();
      final preview = native.requests.firstWhere(
        (r) => r['op'] == 'registrationPreview',
      );
      expect(preview['minRetainedArea'], .8);
      expect(native.requests.any((r) => r['op'] == 'build'), isFalse);

      expect(
          find.textContaining('The common crop is too small.',
              findRichText: true),
          findsOneWidget);
      expect(find.text('62.0%'), findsOneWidget);
      expect(find.textContaining('R_n4_2.fits'), findsWidgets);
      final build = find.widgetWithText(SkotiqButton, 'Build masters');
      expect(tester.widget<SkotiqButton>(build).onPressed, isNull);
      expect(
        find.bySemanticsLabel(RegExp('Overlap map of 48 frames')),
        findsOneWidget,
      );

      native.retained = 1;
      await tapText('Exclude');
      final job = container.read(darkroomBuildJobsProvider)!;
      expect(job.plan!.lights, hasLength(47));
      expect(
        (job.plan!.toJson()['excluded'] as List).single['reason'],
        'Limits the common crop',
      );
      expect(find.textContaining('Framing checked.', findRichText: true),
          findsOneWidget);
      expect(tester.widget<SkotiqButton>(build).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a running build survives closing the window and shows stage, counts and time left',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final job = DarkroomBuildJob(
        target: 'NGC891',
        stage: DarkroomJobStage.building,
        message: 'Building L (2 of 4)',
        startedAt: DateTime(2026, 10, 24, 20),
        directory: '/out/Skotiq-NGC891',
        filter: 'L',
        filterIndex: 1,
        filterCount: 4,
        framesDone: 40,
        framesTotal: 120,
        overallDone: 160,
        overallTotal: 480,
        eta: const Duration(minutes: 95),
        currentImageId: 7,
        filterResults: [
          {
            'filter': 'B',
            'frameCount': 118,
            'totalIntegrationSec': 14160,
            'skipped': [
              {'path': '/b.fits'},
              {'path': '/c.fits'},
            ],
          },
        ],
      );
      await tester.pumpWidget(
        _app(
          [darkroomBuildJobsProvider.overrideWith(() => _PresetJobs(job))],
          Builder(
            builder: (context) => Column(
              children: [
                BuildJobBanner(onOpen: () => showBuildMastersDialog(context)),
                SkotiqButton(
                  label: 'Open dialog',
                  onPressed: () => showBuildMastersDialog(context),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Building masters for NGC891.',
              findRichText: true),
          findsOneWidget);
      expect(
        find.textContaining('160 of 480 lights', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.text('Filter L (2 of 4): light 40 of 120'),
        findsOneWidget,
      );
      expect(find.text('About 1.6 h left'), findsOneWidget);
      expect(find.text('B: 118 frames, 3.93 h'), findsOneWidget);
      expect(find.text('2 left out during processing'), findsOneWidget);
      expect(find.text('Stop after the current light'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(BuildMastersDialog), findsNothing);
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      expect(find.text('Filter L (2 of 4): light 40 of 120'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a narrow window lays the framing review out without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final preview = DarkroomRegistrationPreview.fromJson(
      await _Native().call({
        'op': 'registrationPreview',
        'minRetainedArea': .8,
        'groups': [
          {
            'label': 'Night of 2026-10-24 · R · 120 s',
            'lights': [
              {'path': '/data/NGC891/R_n4_2.fits', 'side': 'East'},
              {'path': '/data/NGC891/R_n4_1.fits', 'side': 'West'},
            ],
          },
        ],
      }),
    );
    final job = DarkroomBuildJob(
      target: 'NGC891',
      stage: DarkroomJobStage.awaitingReview,
      message: preview.describeLimit(),
      startedAt: DateTime(2026, 10, 24),
      preview: preview,
    );
    await tester.pumpWidget(
      _app([
        darkroomBuildJobsProvider.overrideWith(() => _PresetJobs(job)),
      ], const BuildMastersDialog()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Exclude'), findsOneWidget);
    await tester.tap(find.text('By pier side'));
    await tester.pumpAndSettle();
    expect(find.text('East (1)'), findsOneWidget);
    expect(find.text('West (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
