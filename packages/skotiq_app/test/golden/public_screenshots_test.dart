@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/quick_capture_selection.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';

import 'public_screenshots/shot_capture.dart';
import 'public_screenshots/shot_flats.dart';
import 'public_screenshots/shot_night.dart';
import 'public_screenshots/shot_rig.dart';
import 'public_screenshots/shot_tonight.dart';

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
/// Framing, Planetarium and Weather are not in the set: they need survey
/// tiles, the star catalog and radar imagery that a widget test does not
/// have, and rendered here they show their no-data states.
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
    // Decoding the frame and parsing the catalog need real async, which
    // `pump` does not give them.
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
          await seedDarkLibrary(db);
        },
      );
      expect(file.lengthSync(), greaterThan(16 * 1024), reason: shot.fileName);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
