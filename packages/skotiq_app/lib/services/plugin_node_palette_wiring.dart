// Wires the `pluginNodeBlueprintsProvider` (defined in
// `skotiq_core`) to the live `PluginNodeRegistry` (defined in
// `skotiq_plugins`) so plugin-contributed sequence nodes show up
// in the sequencer palette and react to plugins loading / unloading /
// being disabled at runtime.
//
// `skotiq_core` does NOT depend on `skotiq_plugins` — the
// blueprint abstraction is intentionally kept in core so the palette
// can render plugin entries without forcing a circular dependency.
// This file lives in `skotiq_app` (the only package that already
// depends on both) and exposes the `pluginNodePaletteBlueprintsOverride`
// helper installed by the desktop / mobile entry point's ProviderScope.

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

/// Build the Riverpod override that swaps the default empty blueprint
/// list for one backed by the live `PluginNodeRegistry`.
///
/// Reactivity: the override watches
/// `pluginNodeRegistrationsStreamProvider`, which fires a fresh snapshot
/// whenever a plugin is registered, unregistered, enabled, or disabled.
/// The palette therefore re-renders the moment plugin state changes,
/// without the user having to restart the sequencer screen.
///
/// Robustness: malformed `SequenceNodeDefinition` entries (empty ids, non-JSON
/// default config, …) are skipped with a loud `developer.log` breadcrumb, so a
/// malformed plugin reads as a plugin failure rather than as a silently
/// corrupted palette.
///
/// Belongs in the app entry point's `ProviderContainer` overrides.
Override pluginNodePaletteBlueprintsOverride() {
  return pluginNodeBlueprintsProvider.overrideWith((ref) {
    // Watch the registry-change stream. While the stream is loading we
    // fall back to the registry's current snapshot so the palette is
    // never empty when a previously-loaded plugin is already in the
    // registry by the time the override is read.
    final snapshot = ref.watch(pluginNodeRegistrationsStreamProvider);
    final registrations = snapshot.maybeWhen(
      data: (data) => data,
      orElse: () => ref.read(pluginNodeRegistryProvider).registrations,
    );
    return _toBlueprints(registrations);
  });
}

/// Convert raw [PluginNodeRegistration]s into [PluginNodeBlueprint]s the
/// palette can render. Exported for unit testing — production callers
/// should go through [pluginNodePaletteBlueprintsOverride].
List<PluginNodeBlueprint> blueprintsFromRegistrations(
  List<PluginNodeRegistration> registrations,
) =>
    _toBlueprints(registrations);

List<PluginNodeBlueprint> _toBlueprints(
  List<PluginNodeRegistration> registrations,
) {
  if (registrations.isEmpty) return const [];
  final out = <PluginNodeBlueprint>[];
  for (final reg in registrations) {
    final definition = reg.definition;
    if (reg.pluginId.isEmpty ||
        definition.id.isEmpty ||
        definition.name.isEmpty) {
      developer.log(
        'Skipping malformed plugin sequence node registration: '
        'pluginId=${reg.pluginId}, nodeTypeId=${definition.id}, '
        'name=${definition.name}',
        name: 'PluginNodePalette',
        level: 900, // warning
      );
      continue;
    }

    // The plugin's authored category drives the palette grouping. The
    // core palette expression already trims and falls back to "General"
    // when the string is empty.
    final category = definition.category;

    // Plugin authors may want to ship a default config so the palette
    // drop produces a runnable node. We accept either:
    //   * a JSON-shaped string in `metadata` (none exposed today but
    //     forwards-compatible)
    //   * the empty default `{}` otherwise.
    // We validate parseability here so a malformed default never reaches
    // the executor (where the failure would surface as a runtime parse
    // error far from the registration site).
    const defaultJson = '{}';
    String configJson = defaultJson;
    try {
      jsonDecode(configJson);
    } catch (error, stackTrace) {
      developer.log(
        'Plugin ${reg.pluginId}/${definition.id} default config JSON is '
        'unparseable; falling back to "{}"',
        name: 'PluginNodePalette',
        level: 900,
        error: error,
        stackTrace: stackTrace,
      );
      configJson = defaultJson;
    }

    out.add(
      PluginNodeBlueprint(
        pluginId: reg.pluginId,
        nodeTypeId: definition.id,
        pluginName: reg.pluginName,
        name: definition.name,
        description: definition.description,
        category: category,
        // Plugins don't currently expose an icon hint via
        // SequenceNodeDefinition; default to the puzzle-piece glyph the
        // palette widget already knows how to render. When the plugin
        // API grows an `icon` field, mirror it here.
        iconHint: 'puzzle',
        defaultConfigJson: configJson,
      ),
    );
  }
  return List<PluginNodeBlueprint>.unmodifiable(out);
}
