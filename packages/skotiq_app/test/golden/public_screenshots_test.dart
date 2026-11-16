@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/quick_capture_selection.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show CelestialCoordinate;
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show SkyViewNotifier, skyViewStateProvider;

import 'public_screenshots/shot_capture.dart';
import 'public_screenshots/shot_darkroom.dart';
import 'public_screenshots/shot_drive.dart';
import 'public_screenshots/shot_flats.dart';
import 'public_screenshots/shot_framing.dart';
import 'public_screenshots/shot_night.dart';
import 'public_screenshots/shot_rig.dart';
import 'public_screenshots/shot_tonight.dart';
import 'public_screenshots/shot_weather.dart';

/// The product screenshots in `assets/screenshots/`, rendered from the real
/// app (router, shell, screens) over one seeded night: see [ShotNight].
///
/// The set writes into the repository only with `SKOTIQ_CAPTURE_ASSETS=1`;
/// otherwise into a temporary directory. Run it in the site's time zone:
///
///     TZ=America/New_York SKOTIQ_CAPTURE_ASSETS=1 flutter test \
///       --tags golden test/golden/public_screenshots_test.dart
///
/// The phone shots render in a second run with `SKOTIQ_SYSTEM_DECORATIONS=1`,
/// which keeps the desktop window controls out of them (a phone has none):
///
///     TZ=America/New_York SKOTIQ_CAPTURE_ASSETS=1 \
///       SKOTIQ_SYSTEM_DECORATIONS=1 flutter test \
///       --tags golden test/golden/public_screenshots_test.dart
///
/// Each run renders only its half of the set. `SKOTIQ_SHOTS=tonight,guiding`
/// narrows a run to the files whose names contain one of the words.
///
/// What a widget test has no network or disk for comes from fixtures, as an
/// install would have it: the HYG star catalog in the catalog folder, recorded
/// basemap tiles for the Weather map, an SDSS cutout for Framing, the rig's
/// `D:` drive as a scratch folder, and Darkroom previews from the owner's subs
/// (see `test/fixtures/README.md`).
final shots = <Shot>[
  Shot(
    fileName: 'tonight.png',
    location: '/dashboard',
    description: 'Tonight during the run: M31 in LRGB, the plan, the latest '
        'frame, guiding, HFR and focus history and the equipment.',
    overrides: tonightOverrides(),
  ),
  Shot(
    fileName: 'tonight-focus.png',
    location: '/dashboard',
    description: 'Tonight with the Focus tab open: the last autofocus V-curve '
        'and the runs so far tonight.',
    overrides: tonightOverrides(tab: NightPanelTab.focus),
  ),
  Shot(
    fileName: 'tonight-guide.png',
    location: '/dashboard',
    description: 'Tonight with the Guide tab open.',
    overrides: tonightOverrides(tab: NightPanelTab.guide),
  ),
  const Shot(
    fileName: 'plan-best-tonight.png',
    location: '/planner?tab=recommendation',
    description: 'Plan > Best tonight: the OpenNGC catalog ranked for this '
        'site and rig tonight, with the top pick\'s altitude curve.',
    loadTime: Duration(seconds: 8),
  ),
  const Shot(
    fileName: 'plan-targets.png',
    location: '/planner?tab=targets&target=2',
    description: 'Plan > Targets: the three targets with progress toward '
        'their goals, tonight\'s windows and M31\'s detail.',
  ),
  Shot(
    fileName: 'framing.png',
    location: '/planner?tab=framing',
    description: 'Plan > Framing on NGC 7331 with the rig\'s field over the '
        'SDSS color survey; Stephan\'s Quintet sits in the same field.',
    loadTime: const Duration(seconds: 3),
    overrides: framingOverrides(),
  ),
  Shot(
    fileName: 'planetarium.png',
    location: '/planner?tab=planetarium',
    description: 'Plan > Planetarium over Andromeda, Cassiopeia and Perseus '
        'at the scene\'s now, with the HYG star catalog installed.',
    loadTime: const Duration(seconds: 4),
    overrides: [
      skyViewStateProvider.overrideWith(
        (ref) => SkyViewNotifier()
          ..lookAt(const CelestialCoordinate(ra: 1.45, dec: 47))
          ..setFieldOfView(70),
      ),
    ],
  ),
  const Shot(
    fileName: 'sequencer.png',
    location: '/sequencer?tab=builder',
    description: 'Sequencer > Builder with the three-target LRGB plan '
        'running on M31.',
  ),
  const Shot(
    fileName: 'imaging.png',
    location: '/imaging',
    description: 'Imaging > Live view with the latest M31 frame.',
  ),
  const Shot(
    fileName: 'weather.png',
    location: '/weather',
    description: 'Weather: a clear night over the site, the GOES satellite '
        'frame, the alert radius and the forecast.',
    loadTime: Duration(seconds: 2),
  ),
  const Shot(
    fileName: 'guiding.png',
    location: '/guiding',
    description: 'Guiding with PHD2 under 1" RMS.',
  ),
  const Shot(
    fileName: 'equipment.png',
    location: '/equipment?tab=devices',
    description: 'Equipment > Devices with the whole rig connected.',
  ),
  Shot(
    fileName: 'analytics.png',
    location: '/analytics?tab=session',
    description: 'Analytics > Session for last night: HFR, guiding, focus '
        'and sensor temperature for every frame, dusk to dawn.',
    overrides: [
      analyticsSessionPickProvider
          .overrideWith((ref) => ShotNight.lastNight.sessionId),
    ],
  ),
  const Shot(
    fileName: 'analytics-history.png',
    location: '/analytics?tab=history',
    description: 'Analytics > History: every night on record.',
  ),
  Shot(
    fileName: 'night-page.png',
    location: '/analytics?tab=history&night=${ShotNight.lastNight.sessionId}',
    description: 'A night page: last night\'s summary.',
  ),
  const Shot(
    fileName: 'darkroom.png',
    location: '/darkroom',
    description: 'Darkroom > Targets: the L, R, G and B masters built this '
        'morning for the run\'s three targets.',
    loadTime: Duration(seconds: 6),
  ),
  Shot(
    fileName: 'flat-wizard.png',
    location: '/flat-wizard',
    description: 'The flat wizard after this morning\'s LRGB flats on a '
        'flat panel.',
    overrides: flatWizardOverrides(),
    prepare: finishFlatBatch,
  ),
  Shot(
    fileName: 'phone-tonight.png',
    location: '/dashboard',
    description: 'Tonight on a phone.',
    size: Shot.phoneSize,
    pixelRatio: 3,
    overrides: tonightOverrides(),
  ),
  const Shot(
    fileName: 'phone-plan-targets.png',
    location: '/planner?tab=targets',
    description: 'Plan > Targets on a phone.',
    size: Shot.phoneSize,
    pixelRatio: 3,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final only = Platform.environment['SKOTIQ_SHOTS']?.split(',');

  testWidgets('public screenshots', (tester) async {
    // Screens that read a file through path_provider get one scratch folder.
    final scratch = Directory.systemTemp.createTempSync('skotiq_shots_');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => scratch.path,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
    });
    // Map tiles come from the recorded basemap, never the network.
    final tiles = MapTileServer();
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = tiles;
    addTearDown(() {
      HttpOverrides.global = previousOverrides;
      if (missingCutouts.isNotEmpty) {
        // ignore: avoid_print
        print('survey cutouts not in the fixture: ${missingCutouts.join(' ')}');
      }
      if (tiles.missing.isNotEmpty) {
        // ignore: avoid_print
        print('basemap tiles not in the fixture: ${tiles.missing.join(' ')}');
      }
    });
    // Timing the plan, decoding the frame and parsing the catalog need real
    // async, which `pump` does not give them.
    await tester.runAsync(planTonightFromApp);
    // The rig's D: drive, with the frames, masters and calibration files the
    // database names.
    final drive = RigDrive(scratch.path)
      ..put([
        for (final night in ShotNight.nights)
          for (final f in night.frames) ShotNight.filePath(f),
        ...masterPaths(),
        ...calibrationPaths(),
      ]);
    final previousIo = IOOverrides.current;
    IOOverrides.global = drive;
    addTearDown(() => IOOverrides.global = previousIo);
    await tester.runAsync(() async {
      capturedFrame = await loadCapturedFrame();
      await installBuiltInCatalog('${scratch.path}/catalogs');
    });

    for (final shot in shots) {
      if (only != null && !only.any(shot.fileName.contains)) continue;
      if (shot.isPhone != ShellChrome.usesSystemDecorations) continue;
      final file = await captureShot(
        tester,
        shot,
        shared: rigOverrides(),
        stubBackend: stubRigBackend,
        seed: (db) async {
          await ShotNight.seed(db);
          await seedCalibration(db);
          await seedDarkroom(db);
        },
      );
      expect(file.lengthSync(), greaterThan(16 * 1024), reason: shot.fileName);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
