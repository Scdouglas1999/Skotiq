/// Glance mode — a couch-grade "read it from across the room" display toggle.
///
/// When enabled, secondary-status surfaces (the dashboard's smaller telemetry
/// readouts, warning rows, integration tallies, etc.) bump their type up so the
/// operator can read the run state from a few metres away — phone propped on the
/// nightstand, tablet across the observatory. It is deliberately a single
/// boolean: the actual size bump lives in
/// [SkotiqTypography.glance] / [SkotiqTypography.glanceStyle] (UI
/// package) so every surface scales consistently rather than each one inventing
/// its own "big mode" font size.
///
/// The preference persists through the generic key-value [SettingsDao] (the same
/// flexible settings table the auto-stretch / theme knobs use). That table takes
/// arbitrary string keys, so no schema migration is required to add this one —
/// the value is just stored under [_glanceModeKey].
library;

import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';

/// Settings key under which the glance-mode flag is persisted in the
/// key-value [SettingsDao]. Kept private; callers toggle through the notifier.
const String _glanceModeKey = 'glance_mode_enabled';

/// Whether glance mode (large secondary-status type) is currently active.
///
/// Watch this provider where a surface wants to opt into the larger glance type
/// and pass the value to [SkotiqTypography.glanceStyle]. Toggle it via the
/// notifier's [GlanceModeNotifier.setEnabled] / [GlanceModeNotifier.toggle].
final glanceModeProvider = StateNotifierProvider<GlanceModeNotifier, bool>(
  (ref) => GlanceModeNotifier(ref),
);

/// Holds the glance-mode flag and persists changes to the database.
///
/// Loads the stored value once on construction (defaulting to `false` — the
/// normal, dense layout) and writes through on every change so the choice
/// survives an app restart.
class GlanceModeNotifier extends StateNotifier<bool> {
  final Ref _ref;
  bool _isLoaded = false;
  bool _requestedState = false;
  int _requestRevision = 0;
  Future<void> _writeTail = Future<void>.value();
  Future<void> _requestedWrite = Future<void>.value();

  GlanceModeNotifier(this._ref) : super(false) {
    _load();
  }

  /// Load the persisted flag from the key-value settings store. Runs once.
  Future<void> _load() async {
    if (_isLoaded) return;
    _isLoaded = true;
    final revisionAtStart = _requestRevision;

    try {
      final dao = _ref.read(settingsDaoProvider);
      final value = await dao.getSetting(_glanceModeKey);
      if (value != null && revisionAtStart == _requestRevision && mounted) {
        final enabled = value == 'true';
        _requestedState = enabled;
        state = enabled;
      }
    } catch (e) {
      developer.log(
        'Failed to load glance-mode setting: $e',
        name: 'GlanceMode',
        level: 1000,
      );
    }
  }

  /// Set the flag explicitly and persist it. No-ops when unchanged so an
  /// idempotent set doesn't trigger a redundant rebuild or write.
  Future<void> setEnabled(bool enabled) {
    if (enabled == _requestedState) return _requestedWrite;

    _requestedState = enabled;
    final revision = ++_requestRevision;
    final operation = _writeTail.then((_) async {
      try {
        await _persist(enabled);
        if (mounted && revision == _requestRevision) {
          state = enabled;
        }
      } catch (_) {
        if (revision == _requestRevision) {
          _requestedState = state;
        }
        rethrow;
      }
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    _requestedWrite = operation;
    return operation;
  }

  /// Flip the flag and persist.
  Future<void> toggle() => setEnabled(!_requestedState);

  Future<void> _persist(bool enabled) async {
    try {
      final dao = _ref.read(settingsDaoProvider);
      await dao.setSetting(_glanceModeKey, enabled.toString());
    } catch (e) {
      developer.log(
        'Failed to save glance-mode setting: $e',
        name: 'GlanceMode',
        level: 1000,
      );
      rethrow;
    }
  }
}
