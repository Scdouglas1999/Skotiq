// The app has to be able to tell you a new version exists, and then install
// it.
//
// Without a control here, searching Settings for "update" returns About and
// "Appliance updates", which is about a REMOTE rig. This card used to ask the
// releases API itself and could only report, because nothing configured the
// in-app updater with a source. Shipped builds now read the project's GitHub
// releases through that updater, so this card drives the real pipeline: the
// tests below pin what it says in each state and that its buttons reach the
// notifier rather than a browser.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_app/screens/settings/widgets/about_settings.dart';
// `UpdateSettings` is also the name of a freezed model in nightshade_updater,
// so the appliance page is imported under a prefix.
import 'package:nightshade_app/screens/settings/widgets/update_settings.dart'
    as appliance;
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_updater/nightshade_updater.dart';

import '../../harness/harness.dart';

/// Stands in for the real notifier so a test can put the card in any state
/// without disk or network. Every override below is a method the card calls.
class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(Directory supportDirectory)
      : super(
          currentVersion: '6.1.0',
          currentBuildNumber: 21,
          updateService: UpdateService(
            currentVersion: '6.1.0',
            currentBuildNumber: 21,
            applicationSupportDirectoryProvider: () async => supportDirectory,
          ),
        );

  int checks = 0;
  int downloads = 0;
  int applies = 0;

  /// What the next check will find.
  UpdateState Function(UpdateState current)? onCheck;

  @override
  Future<void> checkForUpdates({DateTime? now}) async {
    checks++;
    final next = onCheck;
    if (next != null) state = next(state);
  }

  @override
  Future<void> checkForUpdatesIfDue({DateTime? now}) async {}

  @override
  Future<void> checkStagedUpdate() async {}

  @override
  Future<void> downloadUpdate() async {
    downloads++;
  }

  @override
  Future<void> applyUpdate() async {
    applies++;
  }

  void put(UpdateState next) => state = next;
}

UpdateManifest _manifest(String version) => UpdateManifest(
      version: version,
      buildNumber: 22,
      releaseDate: DateTime.utc(2026, 9, 20),
      platform: 'linux',
      arch: 'x64',
      files: const {},
      totalSize: 0,
      compressedSize: 42 * 1024 * 1024,
      downloadUrl: 'https://example.invalid/pkg.zip',
    );

Future<_FakeUpdateNotifier> _pumpAbout(
  WidgetTester tester, {
  AppVersionInfo version = const AppVersionInfo(
    version: '6.1.0',
    buildNumber: 21,
  ),
  List<Uri>? launched,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('ns-about-update-');
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  final notifier = _FakeUpdateNotifier(tempDir);

  await pumpAppScreen(
    tester,
    const AboutSettings(),
    size: const Size(1200, 1400),
    appVersion: version,
    extraOverrides: [
      updateProvider.overrideWith((ref) => notifier),
      if (launched != null)
        aboutLinkLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
          return true;
        }),
    ],
  );
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the card names a newer release and offers to install it', (
    tester,
  ) async {
    final launched = <Uri>[];
    final notifier = await _pumpAbout(tester, launched: launched);
    notifier.onCheck = (current) => current.copyWith(
          status: UpdateStatus.available,
          availableUpdate: _manifest('6.2.0'),
          sourceConfigured: true,
          releasePageUrl:
              'https://github.com/Scdouglas1999/Nightshade/releases/tag/v6.2.0',
        );

    expect(find.text('Software update'), findsOneWidget);
    expect(find.text('Version 6.1.0 (build 21)'), findsOneWidget);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(notifier.checks, 1);
    expect(find.text('Nightshade 6.2.0 is available.'), findsOneWidget);

    // The install button has to reach the updater, not a download page: that
    // was the whole gap this card used to have.
    await tester.tap(find.text('Download and install'));
    await tester.pumpAndSettle();
    expect(notifier.downloads, 1);

    await tester.tap(find.text('Release notes'));
    await tester.pumpAndSettle();
    expect(
      launched.single.toString(),
      'https://github.com/Scdouglas1999/Nightshade/releases/tag/v6.2.0',
    );
  });

  testWidgets('an up-to-date install is told so, not left guessing', (
    tester,
  ) async {
    final notifier = await _pumpAbout(tester);
    notifier.onCheck = (current) =>
        current.copyWith(status: UpdateStatus.upToDate, sourceConfigured: true);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(
      find.text('You are running the latest release (6.1.0).'),
      findsOneWidget,
    );
    expect(find.text('Download and install'), findsNothing);
  });

  testWidgets('a failed check says so instead of implying you are current', (
    tester,
  ) async {
    final notifier = await _pumpAbout(tester);
    notifier.onCheck = (current) => current.copyWith(
          status: UpdateStatus.error,
          errorMessage: 'the release server answered 503',
        );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not check for updates'), findsOneWidget);
    expect(find.textContaining('503'), findsOneWidget);
  });

  testWidgets(
    'a release with no build for this platform is not read as currency',
    (tester) async {
      // What the published v7.1.0 release actually does to a Linux or
      // Android install: it is a newer release, but it publishes nothing
      // they can install. "You are running the latest release" would be the
      // wrong thing to say about that.
      final notifier = await _pumpAbout(tester);
      notifier.onCheck = (current) => current.copyWith(
            status: UpdateStatus.upToDate,
            sourceConfigured: true,
            unavailableReason:
                'Release v7.2.0 publishes no update that this linux/x64 build '
                'can install.',
          );

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no update that this linux/x64 build can install'),
        findsOneWidget,
      );
      expect(find.textContaining('latest release'), findsNothing);
    },
  );

  testWidgets('a staged update offers to install and restart', (tester) async {
    final notifier = await _pumpAbout(tester);
    notifier.put(
      notifier.state.copyWith(
        status: UpdateStatus.staged,
        availableUpdate: _manifest('6.2.0'),
        stagingPath: '/tmp/staged',
        sourceConfigured: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('6.2.0 is downloaded and ready to install.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Install and restart'));
    await tester.pumpAndSettle();
    expect(notifier.applies, 1);
  });

  testWidgets('a build below the OTA floor is sent to a manual reinstall', (
    tester,
  ) async {
    final notifier = await _pumpAbout(tester);
    notifier.onCheck = (current) => current.copyWith(
          status: UpdateStatus.available,
          availableUpdate: _manifest('7.0.0'),
          requiresManualUpgrade: true,
          sourceConfigured: true,
        );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.textContaining('too old to update in place'), findsOneWidget);
    // Offering an install that the pipeline will refuse would be a lie.
    expect(find.text('Download and install'), findsNothing);
  });

  testWidgets('a build with no source says so rather than claiming currency', (
    tester,
  ) async {
    final notifier = await _pumpAbout(tester);
    notifier.put(
      notifier.state.copyWith(
        status: UpdateStatus.idle,
        sourceConfigured: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('No update source is configured'),
      findsOneWidget,
    );
  });

  testWidgets('the appliance page no longer claims the desktop self-updates', (
    tester,
  ) async {
    await pumpAppScreen(
      tester,
      const appliance.UpdateSettings(),
      size: const Size(1200, 1000),
      settle: false,
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('updates itself through its own installer'),
      findsNothing,
    );
    expect(
      find.textContaining('Settings > About > Check for updates'),
      findsOneWidget,
    );
  });
}
