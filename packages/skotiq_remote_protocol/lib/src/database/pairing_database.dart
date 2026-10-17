import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../server_identity.dart';
import 'device_push_tables.dart';
import 'paired_devices_table.dart';

part 'pairing_database.g.dart';

/// Database for managing paired devices and pairing sessions
@DriftDatabase(
  tables: [PairedDevices, PairingSessions, DevicePushTokens, DevicePushPrefs],
)
class PairingDatabase extends _$PairingDatabase {
  PairingDatabase() : super(_openConnection());

  /// For testing with a custom QueryExecutor
  PairingDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // v1 -> v2: add expires_at column to paired_devices. Existing
        // rows are migrated with NULL (treated as "no expiry" for backward
        // compatibility); new pairings will populate the column going forward.
        if (from < 2) {
          await m.addColumn(pairedDevices, pairedDevices.expiresAt);
        }
        // v2 -> v3 (Phase D): add the cellular-push token + per-device prefs
        // tables. Additive only — existing paired-device rows are untouched;
        // a phone registers its FCM/APNs token after the upgrade and the
        // delivery treats a missing prefs row as "all categories enabled".
        if (from < 3) {
          await m.createTable(devicePushTokens);
          await m.createTable(devicePushPrefs);
        }
        // v3 -> v4: persist the exact authorization grant associated with each
        // paired session token. Legacy rows receive `control`, matching the
        // pre-v4 pairing default without granting admin privileges.
        if (from < 4) {
          await m.addColumn(pairedDevices, pairedDevices.authGrantSpec);
        }
      },
      beforeOpen: (details) async {
        // Enable foreign key enforcement
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }

  // Paired devices operations

  /// Get all active paired devices
  Future<List<PairedDevice>> getActivePairedDevices() async {
    return (select(
      pairedDevices,
    )..where((tbl) => tbl.isActive.equals(true))).get();
  }

  /// Get a specific paired device by device ID
  Future<PairedDevice?> getPairedDevice(String deviceId) async {
    return (select(
      pairedDevices,
    )..where((tbl) => tbl.deviceId.equals(deviceId))).getSingleOrNull();
  }

  /// Resolve the ACTIVE paired device whose session token digests to
  /// [fingerprint] (the `computeServerFingerprint(sessionToken)` value the
  /// headless auth middleware stamps onto every authenticated request).
  ///
  /// This is the inverse of "which deviceId is the caller?": a handler holds
  /// only the digest of the bearer that authenticated the request (never the
  /// raw token), so it cannot trust a client-supplied `deviceId`. It must map
  /// the authenticated session back to its owning device here and compare.
  ///
  /// Revoked devices (`is_active = false`) never match — a deauthorized
  /// session token resolves to no device, so a stolen/revoked token cannot
  /// pass the caller-ownership check. Returns `null` when no active device's
  /// session token matches (anonymous, expired-from-map, or unknown caller).
  Future<PairedDevice?> getActivePairedDeviceByFingerprint(
    String fingerprint,
  ) async {
    if (fingerprint.isEmpty) return null;
    final active = await getActivePairedDevices();
    for (final device in active) {
      // sessionToken is never empty for a real pairing; guard anyway so a
      // malformed row can't throw inside computeServerFingerprint.
      if (device.sessionToken.isEmpty) continue;
      if (computeServerFingerprint(device.sessionToken) == fingerprint) {
        return device;
      }
    }
    return null;
  }

  /// Add a new paired device
  ///
  /// [expiresAt] is the absolute moment after which the issued session token
  /// MUST be rejected by `TokenManager.verifySessionToken` and by the headless
  /// auth middleware. May be `null` only for callers that explicitly opt out
  /// (test fixtures); the production pairing flow always populates it.
  /// [authGrantSpec] is opaque to this storage package and defaults to the
  /// `control` grant. The headless host validates it before use.
  Future<void> addPairedDevice({
    required String deviceId,
    required String deviceName,
    required String sessionToken,
    required String deviceType,
    DateTime? expiresAt,
    String authGrantSpec = 'control',
  }) async {
    await into(pairedDevices).insert(
      PairedDevicesCompanion.insert(
        deviceId: deviceId,
        deviceName: deviceName,
        sessionToken: sessionToken,
        pairedAt: DateTime.now(),
        deviceType: Value(deviceType),
        expiresAt: Value(expiresAt),
        authGrantSpec: Value(authGrantSpec),
      ),
    );
  }

  /// Update the last connected timestamp for a device
  Future<void> updateLastConnected(String deviceId) async {
    await (update(pairedDevices)..where((tbl) => tbl.deviceId.equals(deviceId)))
        .write(PairedDevicesCompanion(lastConnectedAt: Value(DateTime.now())));
  }

  /// Give a paired device an operator-chosen [deviceName].
  ///
  /// The name a device is stored under is whatever the client sent at pairing
  /// time, and the mobile app sends one constant per platform ("Android
  /// companion"), so a household with three phones ends up with three
  /// byte-identical rows and no way to tell which token belongs to the handset
  /// that was sold. Only the host can settle that, so the name is editable
  /// here. Returns the number of rows changed, so a caller can tell a rename
  /// that hit nothing (already deleted) from one that landed.
  Future<int> renamePairedDevice(String deviceId, String deviceName) async {
    return (update(pairedDevices)
          ..where((tbl) => tbl.deviceId.equals(deviceId)))
        .write(PairedDevicesCompanion(deviceName: Value(deviceName)));
  }

  /// Revoke a paired device (mark as inactive).
  ///
  /// The `paired_devices` row is retained (set inactive) for audit, but the
  /// device's cellular-push rows are deleted: a deauthorized phone must stop
  /// receiving FCM/APNs criticals immediately (see `device_push_tables.dart`).
  /// Leaving the token rows would keep fanning out to the revoked device on
  /// every subsequent alert.
  Future<void> revokeDevice(String deviceId) async {
    await (update(pairedDevices)..where((tbl) => tbl.deviceId.equals(deviceId)))
        .write(const PairedDevicesCompanion(isActive: Value(false)));
    await deletePushTokensForDevice(deviceId);
    await deletePushPrefsForDevice(deviceId);
  }

  /// Revoke EVERY currently-active paired device, returning the rows that were
  /// deauthorized (callers need their session tokens to evict live sessions).
  ///
  /// "Take my rig off the network now" is one decision, not one decision per
  /// device: a store inherited from an earlier install can hold a dozen phones
  /// and browsers, and revoking them one dialog at a time is how half of them
  /// get left behind. Each row's cellular-push tokens go with it for the same
  /// reason [revokeDevice] drops them — a deauthorized phone must stop
  /// receiving criticals immediately.
  Future<List<PairedDevice>> revokeAllDevices() async {
    final active = await getActivePairedDevices();
    if (active.isEmpty) return const [];
    await (update(pairedDevices)..where((tbl) => tbl.isActive.equals(true)))
        .write(const PairedDevicesCompanion(isActive: Value(false)));
    for (final device in active) {
      await deletePushTokensForDevice(device.deviceId);
      await deletePushPrefsForDevice(device.deviceId);
    }
    return active;
  }

  /// Delete a paired device completely.
  ///
  /// Also drops the device's cellular-push token + preference rows. Those are
  /// keyed on `deviceId` but have no DB-level FK cascade onto `paired_devices`,
  /// so leaving them behind would orphan the rows: a phone that re-pairs and is
  /// re-assigned the same `deviceId` would silently inherit the deleted
  /// device's stale mute preferences (suppressing safety alerts) and resurrect
  /// a dead push token. Deleting them here keeps a hard-delete clean.
  Future<void> deletePairedDevice(String deviceId) async {
    await (delete(
      pairedDevices,
    )..where((tbl) => tbl.deviceId.equals(deviceId))).go();
    await deletePushTokensForDevice(deviceId);
    await deletePushPrefsForDevice(deviceId);
  }

  // Pairing sessions operations

  /// Create a new pairing session
  Future<int> createPairingSession({
    required String pairingCode,
    required String sessionToken,
    required Duration expiresIn,
  }) async {
    final now = DateTime.now();
    return await into(pairingSessions).insert(
      PairingSessionsCompanion.insert(
        pairingCode: pairingCode,
        sessionToken: sessionToken,
        createdAt: now,
        expiresAt: now.add(expiresIn),
      ),
    );
  }

  /// Get a pairing session by code
  Future<PairingSession?> getPairingSession(String pairingCode) async {
    return (select(
      pairingSessions,
    )..where((tbl) => tbl.pairingCode.equals(pairingCode))).getSingleOrNull();
  }

  /// Mark a pairing session as used
  Future<void> markPairingSessionUsed(String pairingCode) async {
    await (update(pairingSessions)
          ..where((tbl) => tbl.pairingCode.equals(pairingCode)))
        .write(const PairingSessionsCompanion(isUsed: Value(true)));
  }

  /// Delete a pairing session by its code (operator cancelled before use).
  Future<void> deletePairingSession(String pairingCode) async {
    await (delete(
      pairingSessions,
    )..where((tbl) => tbl.pairingCode.equals(pairingCode))).go();
  }

  /// Delete expired pairing sessions (cleanup)
  Future<void> deleteExpiredPairingSessions() async {
    final now = DateTime.now();
    await (delete(
      pairingSessions,
    )..where((tbl) => tbl.expiresAt.isSmallerThanValue(now))).go();
  }

  /// Delete all used pairing sessions
  Future<void> deleteUsedPairingSessions() async {
    await (delete(
      pairingSessions,
    )..where((tbl) => tbl.isUsed.equals(true))).go();
  }

  /// Find all paired-device rows whose session token has either expired
  /// (`expires_at <= now`) or been revoked (`is_active = false`).
  ///
  /// Used by the headless server's periodic sweep to:
  ///  - evict revoked tokens from the in-memory `_pairedSessionTokens` map
  ///    so revocation propagates without a server restart, and
  ///  - delete genuinely expired rows from the DB (revoked rows are retained
  ///    for audit purposes).
  Future<List<PairedDevice>> getExpiredOrRevokedDevices(DateTime now) async {
    final query = select(pairedDevices)
      ..where(
        (tbl) =>
            tbl.isActive.equals(false) |
            (tbl.expiresAt.isNotNull() &
                tbl.expiresAt.isSmallerOrEqualValue(now)),
      );
    return query.get();
  }

  /// Hard-delete a paired-device row whose session token has expired.
  ///
  /// Revoked-but-unexpired rows are kept by [getExpiredOrRevokedDevices]
  /// callers (the headless sweep uses [deletePairedDevice] on the revoked
  /// half only when explicitly requested).
  Future<void> deleteExpiredPairedDevices(DateTime now) async {
    await (delete(pairedDevices)..where(
          (tbl) =>
              tbl.expiresAt.isNotNull() &
              tbl.expiresAt.isSmallerOrEqualValue(now),
        ))
        .go();
  }

  /// Active (`is_active = true`) AND not yet expired (`expires_at IS NULL OR
  /// expires_at > now`). This is the canonical "tokens the auth middleware
  /// should accept" snapshot, used to hydrate the in-memory token map at
  /// server startup.
  Future<List<PairedDevice>> getActiveUnexpiredPairedDevices(
    DateTime now,
  ) async {
    final query = select(pairedDevices)
      ..where(
        (tbl) =>
            tbl.isActive.equals(true) &
            (tbl.expiresAt.isNull() | tbl.expiresAt.isBiggerThanValue(now)),
      );
    return query.get();
  }

  // Device push token operations

  /// Insert-or-update a device's cellular-push token for a platform.
  ///
  /// Keyed on `(deviceId, platform)` so a token refresh (FCM
  /// `onTokenRefresh`, or a fresh APNs registration) overwrites the previous
  /// value in place and bumps `updatedAt`. The `register-token` endpoint and
  /// the mobile re-registration loop both funnel through here.
  Future<void> upsertPushToken({
    required String deviceId,
    required String platform,
    required String token,
  }) async {
    await into(devicePushTokens).insertOnConflictUpdate(
      DevicePushTokensCompanion.insert(
        deviceId: deviceId,
        platform: platform,
        token: token,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// All registered tokens for a platform (`fcm` | `apns`) belonging to an
  /// ACTIVE paired device. This is the list each delivery loops over on
  /// `deliver(frame)`.
  ///
  /// Joined against `paired_devices.is_active = true` so a revoked device is
  /// excluded from fan-out even if its token row somehow lingers (defense in
  /// depth alongside [revokeDevice]'s row deletion — and the expiry sweep,
  /// which retains revoked `paired_devices` rows for audit). A token with no
  /// matching paired-device row is also excluded.
  Future<List<DevicePushToken>> getPushTokensByPlatform(String platform) async {
    final query = select(devicePushTokens).join([
      innerJoin(
        pairedDevices,
        pairedDevices.deviceId.equalsExp(devicePushTokens.deviceId) &
            pairedDevices.isActive.equals(true),
      ),
    ])..where(devicePushTokens.platform.equals(platform));
    final rows = await query.get();
    return rows.map((r) => r.readTable(devicePushTokens)).toList();
  }

  /// All registered tokens across both platforms (diagnostics / fan-out that
  /// is not platform-partitioned).
  Future<List<DevicePushToken>> getAllPushTokens() async {
    return select(devicePushTokens).get();
  }

  /// Tokens registered for a single device (both platforms). Used by the
  /// `DELETE /api/push/token` `{deviceId}` path and by tests.
  Future<List<DevicePushToken>> getPushTokensForDevice(String deviceId) async {
    return (select(
      devicePushTokens,
    )..where((tbl) => tbl.deviceId.equals(deviceId))).get();
  }

  /// Delete every push-token row for a device (unpair / sign-out / revoke).
  Future<void> deletePushTokensForDevice(String deviceId) async {
    await (delete(
      devicePushTokens,
    )..where((tbl) => tbl.deviceId.equals(deviceId))).go();
  }

  /// Delete a single token value — the stale-token cleanup path when the
  /// cloud provider returns `404 UNREGISTERED` (FCM) or `410 Gone` (APNs).
  Future<void> deletePushToken(String token) async {
    await (delete(
      devicePushTokens,
    )..where((tbl) => tbl.token.equals(token))).go();
  }

  // Device push preferences operations

  /// The per-device preferences row, or `null` when the device has never set
  /// one. A null result means "all categories enabled" (the delivery's
  /// conservative default), so callers do not have to seed a row at pairing.
  Future<DevicePushPref?> getPushPrefs(String deviceId) async {
    return (select(
      devicePushPrefs,
    )..where((tbl) => tbl.deviceId.equals(deviceId))).getSingleOrNull();
  }

  /// Insert-or-update a device's preferences row. The endpoint sends the full
  /// row each time (master `enabled` plus every mute flag) so an upsert is the
  /// correct semantics — partial updates would silently re-enable muted
  /// categories.
  Future<void> upsertPushPrefs({
    required String deviceId,
    required bool enabled,
    required bool muteSequenceFailed,
    required bool muteWeatherUnsafe,
    required bool muteGuidingLost,
    required bool muteAutofocusFailed,
    required bool muteEquipmentDisconnected,
  }) async {
    await into(devicePushPrefs).insertOnConflictUpdate(
      DevicePushPrefsCompanion.insert(
        deviceId: deviceId,
        enabled: Value(enabled),
        muteSequenceFailed: Value(muteSequenceFailed),
        muteWeatherUnsafe: Value(muteWeatherUnsafe),
        muteGuidingLost: Value(muteGuidingLost),
        muteAutofocusFailed: Value(muteAutofocusFailed),
        muteEquipmentDisconnected: Value(muteEquipmentDisconnected),
      ),
    );
  }

  /// Delete a device's preferences row (unpair / revoke). Idempotent.
  Future<void> deletePushPrefsForDevice(String deviceId) async {
    await (delete(
      devicePushPrefs,
    )..where((tbl) => tbl.deviceId.equals(deviceId))).go();
  }
}

/// Pins the pairing store beside the Drift application database.
///
/// Repeated rather than imported: this package cannot depend on
/// skotiq_core, which owns the identically-named `skotiqDatabaseDirEnv`
/// that resolves `skotiq.db`. The two must stay in sync — they name the
/// same operator-configured data directory.
const pairingDatabaseDirEnv = 'SKOTIQ_DATABASE_DIR';

/// Resolve where `pairing.db` lives.
///
/// Pairing credentials follow the same configured data directory as the main
/// database so isolated instances cannot share trust state.
///
/// The only `path_provider` call left outside
/// `skotiq_core`'s `resolveSkotiqDocumentsDirectory`, and deliberately
/// so: the dependency edge runs skotiq_core -> skotiq_remote_protocol,
/// so importing the resolver here would close a cycle. Nothing leaks as a
/// result — this file's root is the database directory, which
/// [pairingDatabaseDirEnv] already relocates, and the platform documents
/// folder is only ever the no-override default. The call-site sweep test in
/// skotiq_core names this file as its single exemption.
Future<File> resolvePairingDatabaseFile({
  Map<String, String>? environment,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  final env = environment ?? Platform.environment;
  final overrideDir = env[pairingDatabaseDirEnv]?.trim();
  if (overrideDir != null && overrideDir.isNotEmpty) {
    return File(p.join(overrideDir, 'pairing.db'));
  }

  final dbFolder =
      await (documentsDirectoryProvider ?? getApplicationDocumentsDirectory)();
  return File(p.join(dbFolder.path, 'Skotiq', 'pairing.db'));
}

/// Opt-in for [migrateLegacyPairingStore]. Set to `1`/`true` on an existing
/// daemon whose pairings predate the data-directory override being honoured.
const importLegacyPairingsEnv = 'SKOTIQ_IMPORT_LEGACY_PAIRINGS';

/// One-time carry-forward of a pre-override pairing store, on request only.
///
/// A paired device may drive the mount, so an empty data directory has to mean
/// an empty trust store. Carrying the machine-wide `Documents/Skotiq` store
/// forward automatically made the opposite true: a wiped profile — the thing a
/// user does to revoke access — came back up trusting every phone the install
/// had ever paired, and a scratch instance on a shared machine inherited
/// someone else's. Losing pairings on a data-directory move costs a re-pair;
/// inheriting them costs control of the rig, so this defaults to off.
///
/// It COPIES rather than moves: the legacy file is shared with any install that
/// has no override set, and unpairing that install's devices as a side effect
/// of pointing a daemon at a state directory would be a worse surprise than a
/// duplicate.
Future<void> migrateLegacyPairingStore(
  File target, {
  Map<String, String>? environment,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  final env = environment ?? Platform.environment;
  final optIn = env[importLegacyPairingsEnv]?.trim().toLowerCase();
  if (optIn != '1' && optIn != 'true') return;
  if (await target.exists()) return;

  final dbFolder =
      await (documentsDirectoryProvider ?? getApplicationDocumentsDirectory)();
  final legacy = File(p.join(dbFolder.path, 'Skotiq', 'pairing.db'));
  if (p.equals(legacy.path, target.path)) return;
  if (!await legacy.exists()) return;

  await legacy.copy(target.path);
  // SQLite may have left a hot journal / WAL beside the database. Copying the
  // main file alone would drop committed rows that live only in the sidecar.
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final sidecar = File('${legacy.path}$suffix');
    if (await sidecar.exists()) {
      await sidecar.copy('${target.path}$suffix');
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final file = await resolvePairingDatabaseFile();

    // Ensure directory exists
    await file.parent.create(recursive: true);

    await migrateLegacyPairingStore(file);

    return NativeDatabase.createInBackground(file);
  });
}
