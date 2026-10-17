// C4 — wire the settings-backed plugin-enablement store into C3's
// registration pipeline.
//
// C3 (`skotiq_plugins/src/plugin_registration.dart`) defines the abstract
// [PluginEnablementStore] contract and a settings-agnostic
// `AllEnabledPluginEnablementStore` default. C4
// (`skotiq_core/src/providers/plugin_enablement_provider.dart`) implements
// that contract against the settings database and exposes
// [settingsPluginEnablementStoreProvider].
//
// Neither provider is surfaced through its package barrel (both are internal
// wiring seams), so — exactly like `integrations_settings.dart` and the C4
// provider itself — we import them by path. `skotiq_app` is the only
// package that depends on BOTH `skotiq_core` and `skotiq_plugins`, so
// it is the correct home for the override that bridges them. The
// implementation_imports lint is suppressed deliberately: there is no
// barrel-only alternative for this app-layer composition.
//
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart'
    show settingsPluginEnablementStoreProvider;
import 'package:skotiq_plugins/src/plugin_registration.dart'
    show pluginEnablementStoreProvider;
import 'package:skotiq_plugins/src/plugin_host.dart'
    show PluginHost, pluginHostProvider;

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
