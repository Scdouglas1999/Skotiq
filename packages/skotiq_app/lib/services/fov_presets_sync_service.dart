import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key under which the planetarium FOV framing presets are
/// persisted as a JSON string ([FovPresetsState.toJsonString]).
const String fovPresetsPrefsKey = 'planetarium.fovPresets';

/// Bridges the planetarium's in-memory [fovPresetsProvider] to durable storage.
///
/// The planetarium package is deliberately platform-dependency-free (no
/// `shared_preferences`), so it cannot persist its own state. This app-layer
/// provider closes that gap exactly like [locationSyncProvider] does for the
/// observer location:
///
///  1. on first read it hydrates the provider from SharedPreferences;
///  2. it listens for any change to the preset collection and writes the new
///     JSON back, debounced to the microtask queue so a burst of edits (e.g. a
///     drag that streams many updates) collapses into one write per frame.
///
/// Watch this provider once high in the planetarium screen tree to activate it.
final fovPresetsSyncProvider = Provider<void>((ref) {
  var hydrated = false;
  var disposed = false;
  String? lastWritten;
  ref.onDispose(() => disposed = true);

  Future<void> hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (disposed) return;
      final stored = prefs.getString(fovPresetsPrefsKey);
      if (stored != null && stored.isNotEmpty) {
        ref.read(fovPresetsProvider.notifier).hydrate(stored);
        lastWritten = stored;
      }
    } catch (e, st) {
      developer.log('Failed to hydrate FOV presets: $e',
          name: 'FovPresetsSync', error: e, stackTrace: st);
    } finally {
      if (!disposed) hydrated = true;
    }
  }

  Future<void> persist(FovPresetsState state) async {
    // Don't overwrite storage with the empty default before hydration has had
    // a chance to load the user's saved presets.
    if (!hydrated || disposed) return;
    final json = state.toJsonString();
    if (json == lastWritten) return;
    lastWritten = json;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (disposed) return;
      await prefs.setString(fovPresetsPrefsKey, json);
    } catch (e, st) {
      developer.log('Failed to persist FOV presets: $e',
          name: 'FovPresetsSync', error: e, stackTrace: st);
    }
  }

  // React to every collection change.
  ref.listen<FovPresetsState>(fovPresetsProvider, (previous, next) {
    // Defer to a microtask to avoid touching providers during build and to
    // coalesce same-frame bursts.
    Future.microtask(() => persist(next));
  });

  // Kick off hydration after the current build.
  Future.microtask(hydrate);
});
