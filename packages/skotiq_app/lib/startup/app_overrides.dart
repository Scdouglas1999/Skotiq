import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' show skyNowProvider;

import '../screens/onboarding/steps/capture_dir_step.dart';
import 'plugin_enablement_wiring.dart';
import 'silent_guider_ask_wiring.dart';

/// The provider overrides every Skotiq process starts with, whatever its
/// role: the desktop window, the daemon and the phone app.
List<Override> appProviderOverrides(AppVersionInfo appVersion) => [
      // Throws when unset, so a build with no version cannot run update logic
      // against a made-up one.
      appVersionProvider.overrideWithValue(appVersion),
      pluginHostAppVersionOverride(appVersion.version),
      // A plugin the user disabled stays disabled across launches.
      pluginEnablementStoreOverride(),
      // A GoTo with the guider silent asks the operator on the app's window.
      moveWithSilentGuiderAskOverride(),
      // First-run setup starts with a capture folder made and checked.
      onboardingDefaultCaptureDirectoryProvider
          .overrideWithValue(prepareDefaultCaptureDirectory),
      // The planetarium's sky tells the app's time.
      skyNowProvider.overrideWith((ref) {
        final clock = ref.watch(clockProvider);
        return () => clock.instant;
      }),
    ];
