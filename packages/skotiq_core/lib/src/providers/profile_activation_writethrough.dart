import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/roles/profile_settings_backend.dart';
import '../database/daos/equipment_profiles_dao.dart';
import '../models/equipment_profile_remote_mapping.dart';
import '../services/logging_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// Push the SQLite-active profile into the native (Rust) executor store so the
/// executor's `load_and_set_profile` side effects run.
///
/// SQLite is the source of truth for profile READS, but the Rust executor
/// resolves the active profile from its OWN native store, so an activation
/// made from the GUI must be pushed across or sequencing keeps stale (or
/// empty) active-profile context. The REST `handleLoadProfile` path already
/// write-throughs.
///
/// Host/desktop-only: in remote (slave) mode the backend is a `NetworkBackend`,
/// which has no native store — callers must gate on `isRemoteModeProvider` (or,
/// like [EquipmentProfilesNotifier], only run this on the local backend branch)
/// and route activation through the host REST path instead.
///
/// [dao], [backend] and [logger] are passed in already-resolved so this core
/// performs NO `ref.read` of its own. That matters when the caller is a
/// notifier whose `build()` watches the profile streams: after the DB active
/// flag flips, reading a provider through that notifier's `ref` would trip
/// Riverpod's "dependency changed before rebuild" guard. Notifier call sites
/// therefore resolve their collaborators BEFORE mutating SQLite and hand them
/// here; the [Ref]/[WidgetRef] convenience wrappers below cover the widget and
/// REST-handler call sites where that ordering constraint does not apply.
///
/// [strict] controls legacy direct write-through callers: false keeps their
/// best-effort behaviour; true logs and rethrows. New activation call sites
/// must use [activateProfileStrictTransactional], which makes native acceptance
/// a prerequisite for every SQLite/UI activation, including interactive taps.
Future<void> writeActiveProfileThrough({
  required EquipmentProfilesDao dao,
  required ProfileSettingsBackend backend,
  required LoggingService logger,
  required int profileId,
  bool strict = false,
}) async {
  try {
    final row = await dao.getProfileById(profileId);
    if (row == null) return;
    final remote = dbProfileToRemote(row);
    await backend.saveProfile(remote);
    await backend.loadProfile(remote.id);
  } on Object catch (e, stack) {
    if (strict) {
      logger.error(
        'Active-profile write-through to native store FAILED: $e',
        source: 'ProfileActivationWriteThrough',
        fields: {
          'error': e.toString(),
          'stack': stack.toString(),
          'profileId': profileId.toString(),
        },
      );
      rethrow;
    }
    logger.debug(
      'Active-profile write-through to native store failed: $e',
      source: 'ProfileActivationWriteThrough',
      fields: {'error': e.toString(), 'stack': stack.toString()},
    );
  }
}

/// Raised when a STRICT activation's SQLite commit fails AND the compensating
/// native restore (re-loading the previous active profile into the executor
/// store) ALSO fails. At that point SQLite and the native (Rust) executor store
/// genuinely disagree about which profile is active, and this subsystem must NOT
/// pretend consistency — this composite, high-severity error surfaces BOTH
/// underlying failures so the operator sees the true divergence instead of a
/// swallowed error and a silently split-brained rig.
class ProfileActivationDivergenceError implements Exception {
  /// The profile the caller was trying to make active.
  final int targetProfileId;

  /// The profile that was active before this attempt (the native restore
  /// target), or null if there was no prior active profile to fall back to.
  final int? previousActiveProfileId;

  /// The SQLite commit failure that started the compensation.
  final Object commitError;

  /// The native-restore failure that left the two stores diverged.
  final Object restoreError;

  const ProfileActivationDivergenceError({
    required this.targetProfileId,
    required this.previousActiveProfileId,
    required this.commitError,
    required this.restoreError,
  });

  @override
  String toString() =>
      'ProfileActivationDivergenceError: SQLite/native active-profile state '
      'DIVERGED activating profile $targetProfileId. The SQLite commit failed '
      '($commitError) and restoring the native store to the previous active '
      'profile ${previousActiveProfileId ?? '(none)'} also failed '
      '($restoreError). The native executor may now be running a different '
      'profile than SQLite records as active — resolve manually.';
}

/// STRICT, transactional active-profile activation for every local caller.
///
/// Unlike best-effort [writeActiveProfileThrough] (which flips SQLite FIRST and
/// swallows a native hiccup), this NEVER lets SQLite claim a profile active
/// unless the native (Rust) executor store accepted it first, and it never
/// silently reports success on divergence:
///
///   1. The target row MUST exist. A missing target is an error, not a no-op —
///      startup must not "successfully" activate a profile that isn't there,
///      then connect hardware for it.
///   2. The previous active row is snapshotted up front so the native store can
///      be restored if the SQLite commit later fails.
///   3. The target is pushed into the native store (save THEN load) BEFORE the
///      SQLite active flag is committed. A native failure here throws with
///      SQLite completely untouched — the caller connects nothing and the
///      previous DB active/default selection is preserved exactly.
///   4. Only after native activation succeeds is the SQLite active flag
///      committed. If THAT commit fails, the native store is compensated back to
///      the previous active profile so the two stores agree again, and the
///      original commit error is rethrown.
///   5. If the compensating restore itself fails, a composite
///      [ProfileActivationDivergenceError] is thrown so the true divergence is
///      never hidden behind a claim of consistency.
///
/// [dao], [backend] and [logger] are passed already-resolved (this performs NO
/// `ref.read` of its own) so a notifier whose `build()` watches the profile
/// streams can call it without tripping Riverpod's "dependency changed before
/// rebuild" guard — see [writeActiveProfileThrough] for the same contract.
Future<void> activateProfileStrictTransactional({
  required EquipmentProfilesDao dao,
  required ProfileSettingsBackend backend,
  required LoggingService logger,
  required int profileId,
  Future<void> Function()? commit,
}) async {
  const source = 'ProfileActivationWriteThrough';

  // (1) Validate the target exists BEFORE any mutation. In strict mode a
  //     missing row is an error, not a successful no-op.
  final target = await dao.getProfileById(profileId);
  if (target == null) {
    logger.error(
      'Strict activation aborted: target profile $profileId does not exist',
      source: source,
      fields: {'profileId': profileId.toString()},
    );
    throw StateError(
      'Cannot activate profile $profileId: no such profile row (strict '
      'activation requires an existing target)',
    );
  }

  // (2) Snapshot the previous active profile so we can restore the native store
  //     if the SQLite commit fails after native activation succeeds.
  final previousActive = await dao.getActiveProfile();

  // (3) Native store FIRST. On failure SQLite is untouched (the previous
  //     active/default selection is preserved); rethrow so the caller connects
  //     nothing.
  final targetRemote = dbProfileToRemote(target);
  try {
    await backend.saveProfile(targetRemote);
    await backend.loadProfile(targetRemote.id);
  } on Object catch (e, stack) {
    logger.error(
      'Strict active-profile native write-through FAILED (SQLite left '
      'unchanged): $e',
      source: source,
      fields: {
        'error': e.toString(),
        'stack': stack.toString(),
        'profileId': profileId.toString(),
      },
    );
    rethrow;
  }

  // (4) Commit the SQLite active flag now that the native store accepted it.
  try {
    await (commit?.call() ?? dao.setActiveProfile(profileId));
  } on Object catch (commitError, commitStack) {
    // (5) Compensate: restore the native store to the previous active profile
    //     so the two stores agree again, then rethrow the original commit
    //     error.
    if (previousActive != null) {
      try {
        final previousRemote = dbProfileToRemote(previousActive);
        await backend.saveProfile(previousRemote);
        await backend.loadProfile(previousRemote.id);
      } on Object catch (restoreError, restoreStack) {
        logger.error(
          'Strict activation DIVERGED: SQLite commit failed AND native restore '
          'failed — SQLite and the native executor disagree on the active '
          'profile',
          source: source,
          fields: {
            'profileId': profileId.toString(),
            'previousActiveProfileId': previousActive.id.toString(),
            'commitError': commitError.toString(),
            'restoreError': restoreError.toString(),
            'restoreStack': restoreStack.toString(),
          },
        );
        throw ProfileActivationDivergenceError(
          targetProfileId: profileId,
          previousActiveProfileId: previousActive.id,
          commitError: commitError,
          restoreError: restoreError,
        );
      }
      logger.error(
        'Strict activation SQLite commit failed; native store restored to the '
        'previous active profile ${previousActive.id}: $commitError',
        source: source,
        fields: {
          'profileId': profileId.toString(),
          'previousActiveProfileId': previousActive.id.toString(),
          'error': commitError.toString(),
          'stack': commitStack.toString(),
        },
      );
      rethrow;
    }

    // No previous active row to restore to: the native store now points at the
    // target while SQLite has no committed active row. The ProfileSettings role
    // exposes no "clear active" operation, so this is a genuine divergence we
    // must surface rather than claim consistency.
    logger.error(
      'Strict activation SQLite commit failed with no previous active profile '
      'to restore; the native store points at $profileId while SQLite has no '
      'committed active row: $commitError',
      source: source,
      fields: {
        'profileId': profileId.toString(),
        'error': commitError.toString(),
        'stack': commitStack.toString(),
      },
    );
    throw ProfileActivationDivergenceError(
      targetProfileId: profileId,
      previousActiveProfileId: null,
      commitError: commitError,
      restoreError: StateError(
        'no previous active profile to restore the native store to',
      ),
    );
  }
}

/// [Ref] overload for provider/service call sites that read AFTER any state
/// mutation is safe (i.e. the caller does not `watch` the profile streams).
Future<void> writeActiveProfileThroughToRust(Ref ref, int profileId) {
  return writeActiveProfileThrough(
    dao: ref.read(equipmentProfilesDaoProvider),
    backend: ref.read(profileSettingsBackendProvider),
    logger: ref.read(loggingServiceProvider),
    profileId: profileId,
  );
}

/// WidgetRef overload for GUI call sites (equipment screen, profile editor).
Future<void> writeActiveProfileThroughToRustFromWidget(
  WidgetRef ref,
  int profileId,
) {
  return writeActiveProfileThrough(
    dao: ref.read(equipmentProfilesDaoProvider),
    backend: ref.read(profileSettingsBackendProvider),
    logger: ref.read(loggingServiceProvider),
    profileId: profileId,
  );
}
