// The plugin package's two injection points, filled from the application: the
// persisted enabled-set and the running release.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart'
    show settingsPluginEnablementStoreProvider;
import 'package:skotiq_core/utils.dart' show resolveSkotiqDataDirectory;
import 'package:skotiq_plugins/skotiq_plugins.dart'
    show
        FilePluginStorage,
        PluginContextFactory,
        PluginHost,
        PluginStorage,
        legacyPluginStorageDirectory,
        pluginEnablementStoreProvider,
        pluginHostProvider;

/// Build the Riverpod override that makes the bundled-plugin registration
/// honour the user's persisted enable/disable choices.
///
/// Without this override [pluginEnablementStoreProvider] resolves to the
/// default `DefaultPluginEnablementStore`, which reports each plugin's own
/// default, so a plugin the user disabled on the Integrations page silently
/// comes back enabled on the next launch. The settings-backed store makes the
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

/// Plugin storage under this process's data root, so a relocated instance
/// keeps its own plugin settings. A plugin's file from the folder plugins
/// used before is copied in the first time the plugin reads or writes.
PluginStorage Function(String pluginId) skotiqPluginStorageFactory({
  Future<Directory> Function() dataRoot = resolveSkotiqDataDirectory,
  Future<Directory> Function() legacyRoot = legacyPluginStorageDirectory,
}) {
  Future<Directory>? root;
  return (pluginId) => FilePluginStorage(
        pluginId,
        baseDirectoryProvider: () => root ??= dataRoot(),
        legacyBaseDirectoryProvider: legacyRoot,
      );
}

/// Build the app-composition override that supplies the running Skotiq
/// version to the plugin host's `minAppVersion` gate and the plugins' storage
/// under the app's data root.
Override pluginHostAppVersionOverride(String appVersion) {
  return pluginHostProvider.overrideWith((ref) {
    final host = PluginHost(
      appVersion: appVersion,
      contextFactory: PluginContextFactory(
        storageFactory: skotiqPluginStorageFactory(),
      ),
    );
    ref.onDispose(() {
      unawaited(host.dispose());
    });
    return host;
  });
}
