import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';

import '../screens/onboarding/steps/capture_dir_step.dart';
import '../services/plugin_enablement_wiring.dart';
import '../services/plugin_node_dispatcher_wiring.dart';
import '../services/plugin_node_palette_wiring.dart';

/// The provider overrides every Skotiq process starts with, whatever its
/// role: the desktop window, the daemon and the phone app.
List<Override> appProviderOverrides(AppVersionInfo appVersion) => [
      // Throws when unset, so a build with no version cannot run update logic
      // against a made-up one.
      appVersionProvider.overrideWithValue(appVersion),
      pluginHostAppVersionOverride(appVersion.version),
      // Without the dispatcher every plugin sequence node fails as "not wired".
      pluginNodeDispatcherOverride(),
      // Plugin nodes in the Builder's palette, and in the palette a daemon lists
      // for its clients.
      pluginNodePaletteBlueprintsOverride(),
      // A plugin the user disabled stays disabled across launches.
      pluginEnablementStoreOverride(),
      // First-run setup starts with a capture folder made and checked.
      onboardingDefaultCaptureDirectoryProvider
          .overrideWithValue(prepareDefaultCaptureDirectory),
    ];
