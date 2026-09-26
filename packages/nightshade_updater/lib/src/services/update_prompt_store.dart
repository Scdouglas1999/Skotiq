import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as path;

/// How long a background check waits before asking GitHub again.
///
/// A release lands every few weeks at most, so checking more often than this
/// only spends the operator's GitHub rate limit and, on a rig tethered to a
/// phone hotspot, their data.
const Duration defaultUpdateCheckInterval = Duration(hours: 12);

/// How long "Not now" silences a version before it is offered again.
///
/// Distinct from "Skip this version", which silences it permanently. Someone
/// who dismisses a prompt on the way out to the scope should not be asked
/// again that night, but should not have to remember to go looking for it
/// either.
const Duration defaultUpdateRemindAfter = Duration(days: 3);

/// When the app last checked, and which version the operator waved off.
///
/// Kept beside the other update markers in the data directory rather than in
/// app preferences so it survives the install being replaced: an update that
/// swaps the program directory must not resurrect a prompt the operator
/// already answered.
class UpdatePromptStore {
  final Future<Directory> Function() _dataDirectoryProvider;

  UpdatePromptStore(this._dataDirectoryProvider);

  Future<File> _file() async {
    final root = Directory(
      path.join((await _dataDirectoryProvider()).path, 'updates'),
    );
    if (!await root.exists()) await root.create(recursive: true);
    return File(path.join(root.path, 'prompt_state.json'));
  }

  /// Read the stored state. An unreadable or absent file reads as empty:
  /// losing the record means at worst one extra check and one extra prompt,
  /// which is a far better failure than refusing to ever update again.
  Future<UpdatePromptState> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const UpdatePromptState();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const UpdatePromptState();
      return UpdatePromptState(
        lastCheckAt: _readTime(decoded['lastCheckAt']),
        deferredVersion: switch (decoded['deferredVersion']) {
          final String v when v.trim().isNotEmpty => v,
          _ => null,
        },
        deferredAt: _readTime(decoded['deferredAt']),
      );
    } catch (e) {
      developer.log(
        'Failed to read update prompt state: $e',
        name: 'UpdatePromptStore',
        level: 900,
      );
      return const UpdatePromptState();
    }
  }

  /// Persist [state]. Failure is logged and swallowed so no update flow is
  /// ever blocked by a write that did not land.
  Future<void> write(UpdatePromptState state) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'lastCheckAt': state.lastCheckAt?.toUtc().toIso8601String(),
          'deferredVersion': state.deferredVersion,
          'deferredAt': state.deferredAt?.toUtc().toIso8601String(),
        }),
      );
    } catch (e) {
      developer.log(
        'Failed to persist update prompt state: $e',
        name: 'UpdatePromptStore',
        level: 900,
      );
    }
  }

  static DateTime? _readTime(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}

/// Immutable record of when the app last checked and what it last deferred.
class UpdatePromptState {
  final DateTime? lastCheckAt;
  final String? deferredVersion;
  final DateTime? deferredAt;

  const UpdatePromptState({
    this.lastCheckAt,
    this.deferredVersion,
    this.deferredAt,
  });

  /// Whether enough time has passed to check again.
  ///
  /// A [lastCheckAt] in the future is treated as due rather than trusted: the
  /// rig's clock gets set by hand and by GPS, and a clock that jumped forward
  /// once must not suppress update checks until real time catches up.
  bool isCheckDue(DateTime now, Duration interval) {
    final last = lastCheckAt;
    if (last == null) return true;
    if (last.isAfter(now)) return true;
    return now.difference(last) >= interval;
  }

  /// Whether [version] is currently silenced by a "Not now".
  ///
  /// Only the exact version the operator deferred stays quiet; a newer one
  /// asks immediately, because "not now" was about that build, not about
  /// updates forever. A [deferredAt] in the future expires the deferral for
  /// the same clock reason as above.
  bool isDeferred(String version, DateTime now, Duration remindAfter) {
    if (deferredVersion != version) return false;
    final at = deferredAt;
    if (at == null) return false;
    if (at.isAfter(now)) return false;
    return now.difference(at) < remindAfter;
  }

  UpdatePromptState copyWith({
    DateTime? lastCheckAt,
    String? deferredVersion,
    DateTime? deferredAt,
    bool clearDeferral = false,
  }) {
    if (clearDeferral) {
      return UpdatePromptState(lastCheckAt: lastCheckAt ?? this.lastCheckAt);
    }
    return UpdatePromptState(
      lastCheckAt: lastCheckAt ?? this.lastCheckAt,
      deferredVersion: deferredVersion ?? this.deferredVersion,
      deferredAt: deferredAt ?? this.deferredAt,
    );
  }
}
