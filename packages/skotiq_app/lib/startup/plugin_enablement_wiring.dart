// The plugin package's two injection points, filled from the application: the
// persisted enabled-set and the running release.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart'
    show settingsPluginEnablementStoreProvider;
import 'package:skotiq_plugins/skotiq_plugins.dart'
    show PluginHost, pluginEnablementStoreProvider, pluginHostProvider;

/// Build the Riverpod override that makes the bundled-plugin registration
/// honour the user's persisted enable/disable choices.
///
/// Without this override [pluginEnablementStoreProvider] resolves to the
/// default `AllEnabledPluginEnablementStore`, which reports every plugin
/// enabled — so a plugin the user disabled on the Integrations page silently
/// comes back ENABLED on the next launch. The settings-backed store makes the
/// registration-time decision read the persisted `plugin_enablement` map, so a
/// disabled plugin is registered (loaded) but NOT enabled.
///
/// Belongs in every app entry point's `ProviderScope` / `ProviderContainer`
/// overrides: desktop GUI, desktop headless, mobile.
Override pluginEnablementStoreOverride() {
  return pluginEnablementStoreProvider.overrideWith(
    (ref) => ref.watch(settingsPluginEnablementStoreProvider),
  );
}

/// Build the app-composition override that supplies the running Skotiq
/// version to the plugin host's `minAppVersion` gate.
Override pluginHostAppVersionOverride(String appVersion) {
  return pluginHostProvider.overrideWith((ref) {
    final host = PluginHost(appVersion: appVersion);
    ref.onDispose(() {
      unawaited(host.dispose());
    });
    return host;
  });
}
