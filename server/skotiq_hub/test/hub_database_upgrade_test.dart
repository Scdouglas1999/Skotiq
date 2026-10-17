// Additive-upgrade test for the hub schema (Collaborative Sky 6.0 foundation).
//
// The client carries a versioned Drift migration (covered by
// migration_v55_to_v56_test.dart); the hub deliberately has NO PRAGMA
// user_version gate and evolves purely through `CREATE TABLE IF NOT EXISTS` +
// the guarded `_ensureColumn` helper in `HubDatabase._migrate`. That is correct
// only as long as an OLD production hub DB — one that predates the collaborative
// tables/columns — upgrades cleanly when a 6.0 binary opens it.
//
// This test proves exactly that: it seeds a database file containing ONLY the
// pre-collab legacy tables (accounts WITHOUT suspended_at, contributions /
// raw_subframe_contributions WITHOUT license/consent_id, and none of the collab
// tables), then opens it through `HubDatabase.open` (which runs `_migrate`) and
// asserts the collaborative tables now exist, the `_ensureColumn` columns were
// added to the pre-existing tables, legacy rows survived, and a second open is a
// pure no-op.
//
// It also pins the hardcoded SQLite `license` CHECK constraints (residual #2):
// `shared_calibration_masters.license` and `consent_records.license` embed the
// five ContributionLicense wire names directly in SQL. If that set ever drifts
// from the canonical license set, an INSERT of the new license fails deep in the
// hub with no compile error. This guard makes the divergence a CI failure.

import 'dart:io';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('HubDatabase additive upgrade from a legacy (pre-collab) DB', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('skotiq_hub_upgrade_');
      dbPath = '${tempDir.path}/hub.db';
      _seedLegacyDatabase(dbPath);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    bool tableExists(HubDatabase hub, String name) {
      return hub.db.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
        <Object?>[name],
      ).isNotEmpty;
    }

    bool columnExists(HubDatabase hub, String table, String column) {
      final cols = hub.db.select('PRAGMA table_info($table);');
      return cols.any((r) => r['name'] == column);
    }

    test('creates every collaborative table the legacy DB lacked', () {
      final hub = HubDatabase.open(dbPath);
      try {
        for (final t in const <String>[
          'shared_calibration_masters',
          'collaborative_mosaics',
          'collaborative_mosaic_panels',
          'coimaging_sessions',
          'coimaging_participants',
          'coimaging_batons',
          'consent_records',
          'moderation_actions',
          'artifact_attributions',
        ]) {
          expect(
            tableExists(hub, t),
            isTrue,
            reason: '$t must be created when a pre-collab DB is upgraded',
          );
        }
      } finally {
        hub.dispose();
      }
    });

    test(
      'adds the _ensureColumn columns to the pre-existing legacy tables',
      () {
        final hub = HubDatabase.open(dbPath);
        try {
          // Moderation kill switch on the long-lived accounts table.
          expect(columnExists(hub, 'accounts', 'suspended_at'), isTrue);
          expect(columnExists(hub, 'accounts', 'suspended_reason'), isTrue);
          // Consent/license stamps on the two contribution ledgers.
          expect(columnExists(hub, 'contributions', 'license'), isTrue);
          expect(columnExists(hub, 'contributions', 'consent_id'), isTrue);
          expect(
            columnExists(hub, 'raw_subframe_contributions', 'license'),
            isTrue,
          );
          expect(
            columnExists(hub, 'raw_subframe_contributions', 'consent_id'),
            isTrue,
          );
          // The collab tables created this pass also carry their _ensureColumn
          // additions (these columns are NOT in the base CREATE).
          expect(
            columnExists(
              hub,
              'collaborative_mosaic_panels',
              'attribution_consent',
            ),
            isTrue,
          );
          expect(
            columnExists(hub, 'coimaging_participants', 'attribution_consent'),
            isTrue,
          );
        } finally {
          hub.dispose();
        }
      },
    );

    test('preserves the legacy rows across the upgrade', () {
      final hub = HubDatabase.open(dbPath);
      try {
        final accounts = hub.db.select(
          'SELECT id, display_name FROM accounts WHERE id = ?;',
          <Object?>['acct-legacy'],
        );
        expect(accounts, hasLength(1));
        expect(accounts.single['display_name'], 'Legacy Imager');

        final contribs = hub.db.select(
          'SELECT id, license FROM contributions WHERE id = ?;',
          <Object?>['contrib-legacy'],
        );
        expect(contribs, hasLength(1));
        expect(
          contribs.single['license'],
          isNull,
          reason: 'the newly-added license column is NULL on a legacy row',
        );
      } finally {
        hub.dispose();
      }
    });

    test('a second open is an idempotent no-op that keeps the data', () {
      HubDatabase.open(dbPath).dispose();
      final hub = HubDatabase.open(dbPath);
      try {
        expect(tableExists(hub, 'shared_calibration_masters'), isTrue);
        expect(columnExists(hub, 'accounts', 'suspended_at'), isTrue);
        final accounts = hub.db.select(
          'SELECT id FROM accounts WHERE id = ?;',
          <Object?>['acct-legacy'],
        );
        expect(
          accounts,
          hasLength(1),
          reason: 're-running _migrate must not drop or duplicate data',
        );
        // The migrated DB is fully usable: a scoped token mints + resolves.
        final tokens = TokenService(hub);
        final raw = tokens.issue(
          accountId: 'acct-legacy',
          scope: HubScope.contribute,
        );
        expect(tokens.resolve(raw)!.scope, HubScope.contribute);
      } finally {
        hub.dispose();
      }
    });
  });

  group('license CHECK constraint stays in lock-step with the wire set', () {
    // The canonical ContributionLicense wire names. skotiq_hub cannot import
    // skotiq_core (Flutter/Drift dep), so the set is mirrored here; the
    // skotiq_core side pins ContributionLicense.values against the SAME set
    // (collaboration_models_test.dart), so adding a license forces BOTH guards to
    // be updated — and this one proves the hub's SQL CHECK matches.
    const canonical = <String>{
      'private',
      'cc0',
      'cc-by',
      'cc-by-sa',
      'cc-by-nc',
    };

    Set<String> licenseCheckSet(HubDatabase hub, String table) {
      final rows = hub.db.select(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;",
        <Object?>[table],
      );
      expect(rows, hasLength(1), reason: '$table must exist');
      final sql = rows.single['sql'] as String;
      // Extract the `license IN ('a','b',...)` set from the CHECK clause.
      final match = RegExp(
        r"license\s+IN\s*\(([^)]*)\)",
        caseSensitive: false,
      ).firstMatch(sql);
      expect(
        match,
        isNotNull,
        reason:
            '$table.license must carry a CHECK (license IN (...)) constraint',
      );
      return RegExp(
        "'([^']*)'",
      ).allMatches(match!.group(1)!).map((m) => m.group(1)!).toSet();
    }

    test(
      'shared_calibration_masters + consent_records CHECK == canonical set',
      () {
        final hub = HubDatabase.open(':memory:');
        try {
          expect(
            licenseCheckSet(hub, 'shared_calibration_masters'),
            equals(canonical),
            reason:
                'the shared_calibration_masters.license CHECK must accept exactly '
                'the ContributionLicense wire names — a drift silently rejects '
                'valid publishes at INSERT time',
          );
          expect(
            licenseCheckSet(hub, 'consent_records'),
            equals(canonical),
            reason: 'the consent_records.license CHECK must match the same set',
          );
        } finally {
          hub.dispose();
        }
      },
    );
  });
}

/// Seed a database file at [path] with ONLY the pre-collaborative legacy tables —
/// the schema a hub running before 6.0 would have on disk. Deliberately omits
/// every collaborative table and the `_ensureColumn`-added columns (accounts has
/// no suspended_*, the contribution ledgers have no license/consent_id) so that
/// opening it through `HubDatabase.open` exercises the real additive upgrade.
void _seedLegacyDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = ON;');

    // Legacy accounts — no suspended_at / suspended_reason.
    db.execute('''
      CREATE TABLE accounts (
        id            TEXT PRIMARY KEY,
        display_name  TEXT NOT NULL,
        public_key    TEXT NOT NULL,
        password_hash TEXT,
        trust         REAL NOT NULL DEFAULT 0.5,
        is_admin      INTEGER NOT NULL DEFAULT 0,
        residual_sum  REAL NOT NULL DEFAULT 0,
        residual_n    INTEGER NOT NULL DEFAULT 0,
        accepted_frames INTEGER NOT NULL DEFAULT 0,
        rejected_frames INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL,
        UNIQUE (public_key)
      );
    ''');

    db.execute('''
      CREATE TABLE tokens (
        token_hash TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        scope      TEXT NOT NULL,
        created_at TEXT NOT NULL,
        expires_at TEXT
      );
    ''');

    // Legacy contributions — no license / consent_id.
    db.execute('''
      CREATE TABLE contributions (
        id            TEXT PRIMARY KEY,
        account_id    TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        tile_id       INTEGER NOT NULL,
        healpix_order INTEGER NOT NULL,
        frames_delta  INTEGER NOT NULL,
        integration_seconds_delta REAL NOT NULL,
        median_fwhm   REAL,
        trust_applied REAL NOT NULL,
        status        TEXT NOT NULL,
        delta_path    TEXT NOT NULL,
        instrument    TEXT,
        solver        TEXT,
        created_at    TEXT NOT NULL
      );
    ''');

    // Legacy raw subframe ledger — no license / consent_id.
    db.execute('''
      CREATE TABLE raw_subframe_contributions (
        contribution_id   TEXT PRIMARY KEY,
        account_id        TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        tile_id           INTEGER NOT NULL,
        healpix_order     INTEGER NOT NULL,
        captured_image_id INTEGER,
        path              TEXT NOT NULL,
        bytes             INTEGER NOT NULL,
        instrument        TEXT,
        exposure_seconds  REAL,
        received_at       TEXT NOT NULL
      );
    ''');

    final now = DateTime.now().toUtc().toIso8601String();
    db.execute(
      'INSERT INTO accounts (id, display_name, public_key, created_at) '
      'VALUES (?, ?, ?, ?);',
      <Object?>['acct-legacy', 'Legacy Imager', 'pk-legacy', now],
    );
    db.execute(
      'INSERT INTO contributions '
      '(id, account_id, tile_id, healpix_order, frames_delta, '
      'integration_seconds_delta, trust_applied, status, delta_path, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        'contrib-legacy',
        'acct-legacy',
        7,
        5,
        10,
        600.0,
        1.0,
        'accepted',
        '/data/contrib-legacy.nst',
        now,
      ],
    );
  } finally {
    db.dispose();
  }
}
