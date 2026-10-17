// Plugin enablement persistence.
//
// Persists the user's per-plugin enable/disable choices as ONE `app_settings`
// JSON key (no DB schema change — reuses [SettingsDao.getSetting]/[setSetting]).
//
// Default policy: a plugin id that is ABSENT from the persisted map reads as
// ENABLED. The four bundled integrations therefore start on; a user must
// explicitly disable one (which writes `<id>: false`). This matches the C3
// package's [AllEnabledPluginEnablementStore] fallback so the app- and
// package-level defaults never diverge.
//
// This is the seam where `skotiq_core` meets `skotiq_plugins`:
//   * C3 (`skotiq_plugins/plugin_registration.dart`) defines the abstract
//     [PluginEnablementStore] contract and a settings-agnostic
//     `AllEnabledPluginEnablementStore` default.
//   * C4 (this file) implements that contract against the settings database
//     and exposes the live enabled-set to the UI.
//
// Dependency direction: `skotiq_core` depends on `skotiq_plugins`
// (not the reverse — `skotiq_plugins` has no `skotiq_core` import, so
// there is no cycle). Core implements the plugins-package interface; the app
// wires it by overriding `pluginEnablementStoreProvider` (defined in C3) with
// [settingsPluginEnablementStoreProvider] from here.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
// C3 ships the [PluginEnablementStore] contract and the canonical
// [kUserFacingExamplePlugins] list in `plugin_registration.dart`. That file is
// C3's public seam for exactly this app-layer wiring (its doc comments name
// "C4 / the app layer" as the intended implementor), but it is not surfaced
// through the package barrel, so we must import it by path. The
// implementation_imports lint is suppressed deliberately: our concrete
// SettingsPluginEnablementStore MUST be a subtype of C3's exact
// PluginEnablementStore type for the app's `pluginEnablementStoreProvider`
// override to typecheck, so there is no barrel-only alternative.
// ignore: implementation_imports
import 'package:skotiq_plugins/src/plugin_registration.dart';
// The live [PluginHost] is the authoritative runtime for the bundled plugins.
// `setEnabled` must drive it (run onEnable/onDisable, register/unregister the
// plugin's sequence nodes) so the persisted choice and the running session
// never diverge — persisting the bit alone would leave a "disabled" plugin
// still firing for the rest of the session. `pluginHostProvider` lives in
// `plugin_host.dart`, which is exported through the package barrel, but we
// import it by path alongside `plugin_registration.dart` so this seam reaches
// exactly the same host the registration pipeline populated.
// ignore: implementation_imports
import 'package:skotiq_plugins/src/plugin_host.dart';

import '../database/daos/settings_dao.dart';
import 'database_provider.dart';

final _log = Logger('PluginEnablementProvider');

/// `app_settings` key holding the per-plugin enablement map.
///
/// The stored value is a JSON object `{ "<pluginId>": bool }`. Only explicit
/// user choices are recorded; an absent id is treated as enabled (see the file
/// header), so a fresh install persists nothing and every bundled plugin runs.
const String kPluginEnablementSettingKey = 'plugin_enablement';

/// Default enablement for a plugin id that has no persisted choice.
///
/// Centralised so the notifier, the store, and tests all agree on the policy.
const bool kPluginEnabledByDefault = true;

/// Parses the persisted enablement JSON into a `{ id: bool }` map.
///
/// Returns an empty map (i.e. "no explicit choices → everything default") for
/// `null`/empty input. Malformed JSON is NOT silently swallowed: it is logged
/// at WARNING with the offending value and then treated as "no explicit
/// choices", which fails *closed to enabled* (the safe, fresh-install state).
/// The log is what makes a corrupted settings row diagnosable instead of
/// mysteriously turning integrations off.
Map<String, bool> _decodeEnablementMap(String? raw) {
  if (raw == null || raw.isEmpty) {
    return const <String, bool>{};
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException(
        'plugin_enablement value is not a JSON object',
      );
    }
    final result = <String, bool>{};
    decoded.forEach((key, value) {
      if (key is String && value is bool) {
        result[key] = value;
      } else {
        // A malformed entry (non-string key or non-bool value) is a corruption
        // signal, not something to paper over silently. Surface it and skip the
        // single bad entry rather than discarding the whole map.
        _log.warning(
          'Ignoring malformed plugin_enablement entry: '
          '$key=$value (expected String=>bool)',
        );
      }
    });
    return result;
  } on FormatException catch (error, stackTrace) {
    _log.warning(
      'Malformed plugin_enablement JSON; defaulting all plugins to enabled. '
      'Raw value: $raw',
      error,
      stackTrace,
    );
    return const <String, bool>{};
  }
}

/// Resolves the enabled set from a decoded choice map for [allPluginIds].
///
/// An id absent from [choices] resolves to [kPluginEnabledByDefault]. Only ids
/// in [allPluginIds] are considered so a stale persisted id (e.g. a plugin that
/// was removed from a build) never leaks into the live set.
Set<String> _enabledSetFor(
  Map<String, bool> choices,
  Iterable<String> allPluginIds,
) {
  return {
    for (final id in allPluginIds)
      if (choices[id] ?? kPluginEnabledByDefault) id,
  };
}

/// The full set of plugin ids whose enablement this layer manages.
///
/// Sourced from the C3 canonical list so the two packages never disagree on
/// "which plugins exist". Exposed as a provider so tests can override it with a
/// fixed id set without touching the package-level list.
final managedPluginIdsProvider = Provider<List<String>>((ref) {
  return [for (final d in kUserFacingExamplePlugins) d.id];
});

/// Live, persisted set of enabled plugin ids.
///
/// `build()` loads the persisted choice map and resolves it against
/// [managedPluginIdsProvider]; [setEnabled] mutates one id and persists the
/// whole map back. The exposed state is exactly the set of ids that should be
/// enabled right now.
final pluginEnablementProvider =
    AsyncNotifierProvider<PluginEnablementNotifier, Set<String>>(
      PluginEnablementNotifier.new,
    );

/// AsyncNotifier backing [pluginEnablementProvider].
class PluginEnablementNotifier extends AsyncNotifier<Set<String>> {
  Future<void> _mutationTail = Future<void>.value();

  SettingsDao get _dao => ref.read(settingsDaoProvider);

  List<String> get _managedIds => ref.read(managedPluginIdsProvider);

  @override
  Future<Set<String>> build() async {
    final raw = await _dao.getSetting(kPluginEnablementSettingKey);
    final choices = _decodeEnablementMap(raw);
    return _enabledSetFor(choices, _managedIds);
  }

  /// Whether [pluginId] is currently enabled.
  ///
  /// Unknown / not-yet-loaded ids resolve to [kPluginEnabledByDefault] so this
  /// is safe to call before [build] completes or for ids outside the managed
  /// list.
  bool isEnabled(String pluginId) {
    final current = state.valueOrNull;
    if (current == null) {
      return kPluginEnabledByDefault;
    }
    if (_managedIds.contains(pluginId)) {
      return current.contains(pluginId);
    }
    return kPluginEnabledByDefault;
  }

  /// Persists [enabled] for [pluginId], drives the live [PluginHost], and
  /// updates the live set.
  ///
  /// Three effects, in order:
  ///   1. Drive the running host first — when the plugin is loaded in the live
  ///      [PluginHost], `host.setPluginEnabled` runs its `onEnable`/`onDisable`
  ///      and registers/unregisters its sequence nodes, so a disabled plugin
  ///      actually stops firing THIS session (not just next launch). This runs
  ///      FIRST so that if the lifecycle transition throws, we have NOT
  ///      persisted a choice the live host failed to honour — the persisted
  ///      state and the running host never diverge. A no-op transition (the
  ///      host is already in the target state) is fine. A genuine lifecycle
  ///      failure surfaces rather than being swallowed.
  ///   2. Persist the choice — reads the current persisted choice map (so
  ///      unrelated, possibly not-yet-managed ids survive), writes the single
  ///      changed entry, and saves the whole map back under
  ///      [kPluginEnablementSettingKey].
  ///   3. Recompute the in-memory state from the new map so observers see the
  ///      change immediately.
  ///
  /// When the id is NOT loaded in the host (a headless build that doesn't run
  /// that plugin, or a context where registration hasn't happened), the host
  /// step is skipped and only the persisted choice is written — the
  /// settings-backed enablement store replays that choice into the registration
  /// pipeline the next time the plugins load, so the saved state still wins.
  Future<void> setEnabled(String pluginId, bool enabled) {
    final operation = _mutationTail.then((_) async {
      // 1. Transition the live host first (only if it actually holds this
      //    plugin). We deliberately do NOT throw for a not-loaded id: the host
      //    is the authority for "what's running right now", and an id that
      //    isn't loaded has nothing to transition — the persisted choice below
      //    is what makes it take effect at next registration.
      final host = ref.read(pluginHostProvider);
      final isLoaded = host.isLoaded(pluginId);
      final wasEnabled = isLoaded ? host.isEnabled(pluginId) : null;
      final hostNeedsTransition = isLoaded && wasEnabled != enabled;
      if (hostNeedsTransition) {
        await host.setPluginEnabled(pluginId, enabled);
      }

      try {
        // 2. Persist the user's choice. This read-modify-write runs inside the
        // mutation queue so parallel toggles cannot drop unrelated ids.
        final raw = await _dao.getSetting(kPluginEnablementSettingKey);
        final choices = Map<String, bool>.from(_decodeEnablementMap(raw));
        choices[pluginId] = enabled;

        await _dao.setSetting(kPluginEnablementSettingKey, jsonEncode(choices));

        // 3. Publish the new live set.
        state = AsyncData(_enabledSetFor(choices, _managedIds));
      } catch (error, stackTrace) {
        // Securely persisting the choice is part of the same user action as
        // changing the live host. If persistence fails, restore the prior live
        // state so the UI, current process, and next launch still agree.
        if (hostNeedsTransition && wasEnabled != null) {
          try {
            await host.setPluginEnabled(pluginId, wasEnabled);
          } catch (rollbackError, rollbackStackTrace) {
            _log.severe(
              'Failed to roll back live plugin $pluginId after its '
              'enablement preference could not be saved.',
              rollbackError,
              rollbackStackTrace,
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
    _mutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }
}

/// Settings-backed [PluginEnablementStore] for the C3 registration pipeline.
///
/// C3 (`plugin_registration.dart`) asks this at startup, per plugin, whether to
/// register the plugin in the enabled state. We answer from the persisted
/// choice map with the same default-enabled policy as [PluginEnablementNotifier]
/// so the registration-time decision and the live UI set are always consistent.
///
/// Reads the DAO directly (rather than the notifier) so this works even before
/// [pluginEnablementProvider] has been read, and never throws for unknown ids.
class SettingsPluginEnablementStore implements PluginEnablementStore {
  const SettingsPluginEnablementStore(this._dao);

  final SettingsDao _dao;

  @override
  Future<bool> isEnabled(String pluginId) async {
    final raw = await _dao.getSetting(kPluginEnablementSettingKey);
    final choices = _decodeEnablementMap(raw);
    return choices[pluginId] ?? kPluginEnabledByDefault;
  }
}

/// Concrete store the app layer overrides `pluginEnablementStoreProvider`
/// with at its composition root.
final settingsPluginEnablementStoreProvider =
    Provider<SettingsPluginEnablementStore>((ref) {
      return SettingsPluginEnablementStore(ref.watch(settingsDaoProvider));
    });
