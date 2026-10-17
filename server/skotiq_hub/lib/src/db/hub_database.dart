import 'package:sqlite3/sqlite3.dart';

/// Embedded sqlite store for the Constellation hub. Chosen over postgres for
/// self-host parity: a single file (or `:memory:` in tests) and the system
/// `libsqlite3`, no external service. Schema is created idempotently on open.
///
/// Tables:
///  - `accounts`        — identity + auth (password hash, public key, trust)
///  - `tokens`          — issued bearer tokens (SHA-256 of the raw token only)
///  - `shared_targets`  — cone-addressable shared targets ("follow-the-night")
///  - `contributions`   — per-contributor upload ledger (for retraction + audit)
///  - `tile_index`      — per-tile fused summary (frames, seconds, contributors)
///  - `raw_subframe_contributions` — per-account raw FITS subframe ledger (the
///    opt-in `acceptsRawSubs` path; one row per stored frame, file on disk)
///  - `handoff_claims`  — single-holder follow-the-night claim per target
///  - `audit_log`       — append-only request audit trail
///  - `shared_calibration_masters` — published masters keyed by the full
///    calibration tuple + provenance
///  - `collaborative_mosaics` / `collaborative_mosaic_panels` — a published
///    mosaic grid whose panels are claimable distributed work items
///  - `coimaging_sessions` / `coimaging_participants` — live co-imaging session
///    state + per-rig membership with assigned framing offsets
///  - `coimaging_batons` — per-session longitude-baton claim, isolated from the
///    cone-merged shared target so sessions cannot seize each other's baton
class HubDatabase {
  HubDatabase._(this.db);

  final Database db;

  /// Open a hub database at [path] (use `':memory:'` for tests) and ensure the
  /// schema exists. Foreign keys are enforced; WAL improves concurrent reads.
  factory HubDatabase.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON;');
    if (path != ':memory:') {
      db.execute('PRAGMA journal_mode = WAL;');
    }
    final hub = HubDatabase._(db);
    hub._migrate();
    return hub;
  }

  void _migrate() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
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
      CREATE TABLE IF NOT EXISTS tokens (
        token_hash TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        scope      TEXT NOT NULL,
        created_at TEXT NOT NULL,
        expires_at TEXT
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS shared_targets (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        name          TEXT NOT NULL,
        center_ra_deg REAL NOT NULL,
        center_dec_deg REAL NOT NULL,
        radius_deg    REAL NOT NULL,
        priority      REAL NOT NULL DEFAULT 0.5,
        integration_seconds REAL NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS tile_index (
        tile_id       INTEGER NOT NULL,
        healpix_order INTEGER NOT NULL,
        channels      INTEGER NOT NULL,
        center_ra_deg REAL NOT NULL,
        center_dec_deg REAL NOT NULL,
        total_frames  INTEGER NOT NULL DEFAULT 0,
        integration_seconds REAL NOT NULL DEFAULT 0,
        contributors  INTEGER NOT NULL DEFAULT 0,
        sidecar_path  TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        PRIMARY KEY (tile_id, healpix_order)
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS contributions (
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
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_contrib_tile '
      'ON contributions(tile_id, healpix_order);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_contrib_account '
      'ON contributions(account_id);',
    );

    // Raw subframe ledger (the opt-in `acceptsRawSubs` path). Unlike additive
    // sums, each raw FITS lives as its own file on disk and its own row here so
    // a single-frame DELETE is an exact file-delete. `contribution_id` is the
    // opaque handle the client persists and later retracts on.
    db.execute('''
      CREATE TABLE IF NOT EXISTS raw_subframe_contributions (
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
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_sub_tile '
      'ON raw_subframe_contributions(tile_id, healpix_order);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_sub_account '
      'ON raw_subframe_contributions(account_id);',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS handoff_claims (
        target_id   INTEGER PRIMARY KEY REFERENCES shared_targets(id)
                       ON DELETE CASCADE,
        account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        claim_token TEXT NOT NULL,
        claimed_at  TEXT NOT NULL,
        expires_at  TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        at         TEXT NOT NULL,
        account_id TEXT,
        method     TEXT NOT NULL,
        path       TEXT NOT NULL,
        status     INTEGER NOT NULL,
        detail     TEXT
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log(at);');

    // --- Collaborative Sky (6.0) -------------------------------------------

    // Shared calibration masters. One row per published master, keyed by
    // the full calibration tuple the client matcher scores on, plus provenance
    // (camera, frame count, dark current, who shot it) and consent (license).
    // Darks/bias are sensor-keyed; flats carry the optics-specific
    // `optical_train` so the matcher can refuse cross-train flat reuse. The
    // master file lives on disk at `path`; `provenance_json` is a serialized
    // Provenance, `license` a ContributionLicense wire name.
    //
    // TRUST: `account_id` is the AUTHORITATIVE producer identity (FK to the
    // authenticated account). The `accountId`/`displayName` fields embedded in
    // `provenance_json` are self-reported, untrusted client hints — the publish
    // path stamps them from the authenticated principal
    // (`stampAuthoritativeProvenanceIdentity`) and all attribution rendering
    // MUST join on `account_id`, never the JSON identity. The `license` CHECK
    // rejects unknown wire names at write time so a tampered/forward-version
    // value can never widen the granted reuse rights past the known set, and the
    // column defaults to fail-closed `'private'` (matching the decode-side
    // `ContributionLicense.private` fallback) so a publish path that omits the
    // license can never silently grant reuse the producer never consented to —
    // every share must record an explicit consented license.
    db.execute('''
      CREATE TABLE IF NOT EXISTS shared_calibration_masters (
        id                TEXT PRIMARY KEY,
        account_id        TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        master_type       TEXT NOT NULL,
        camera_model      TEXT NOT NULL,
        sensor_width      INTEGER NOT NULL DEFAULT 0,
        sensor_height     INTEGER NOT NULL DEFAULT 0,
        gain              INTEGER NOT NULL DEFAULT 0,
        offset_value      INTEGER NOT NULL DEFAULT 0,
        exposure_seconds  REAL NOT NULL DEFAULT 0,
        temperature_c     REAL,
        bin_x             INTEGER NOT NULL DEFAULT 1,
        bin_y             INTEGER NOT NULL DEFAULT 1,
        filter            TEXT,
        optical_train     TEXT,
        frame_count       INTEGER NOT NULL DEFAULT 0,
        dark_current      REAL,
        license           TEXT NOT NULL DEFAULT 'private'
                            CHECK (license IN
                              ('private','cc0','cc-by','cc-by-sa','cc-by-nc')),
        provenance_json   TEXT NOT NULL DEFAULT '{}',
        path              TEXT NOT NULL,
        bytes             INTEGER NOT NULL DEFAULT 0,
        created_at        TEXT NOT NULL
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shared_cal_match '
      'ON shared_calibration_masters'
      '(master_type, camera_model, gain, offset_value, bin_x, bin_y);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shared_cal_account '
      'ON shared_calibration_masters(account_id);',
    );

    // Collaborative mosaics. The published grid; panels are claimable work
    // items brokered with the hand-off baton pattern (one holder per panel).
    db.execute('''
      CREATE TABLE IF NOT EXISTS collaborative_mosaics (
        id                TEXT PRIMARY KEY,
        owner_account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        name              TEXT NOT NULL,
        rows              INTEGER NOT NULL,
        cols              INTEGER NOT NULL,
        overlap_pct       REAL NOT NULL DEFAULT 15.0,
        position_angle_deg REAL NOT NULL DEFAULT 0.0,
        center_ra_deg     REAL NOT NULL,
        center_dec_deg    REAL NOT NULL,
        status            TEXT NOT NULL DEFAULT 'open',
        output_sidecar_path TEXT,
        created_at        TEXT NOT NULL,
        updated_at        TEXT NOT NULL
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_collab_mosaic_owner '
      'ON collaborative_mosaics(owner_account_id);',
    );
    db.execute('''
      CREATE TABLE IF NOT EXISTS collaborative_mosaic_panels (
        id                TEXT PRIMARY KEY,
        mosaic_id         TEXT NOT NULL REFERENCES collaborative_mosaics(id)
                            ON DELETE CASCADE,
        panel_index       INTEGER NOT NULL,
        center_ra_deg     REAL NOT NULL,
        center_dec_deg    REAL NOT NULL,
        assigned_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
        assigned_rig_id   TEXT,
        claim_token       TEXT,
        claim_expires_at  TEXT,
        uploaded_master_path TEXT,
        uploaded_master_id   TEXT,
        status            TEXT NOT NULL DEFAULT 'pending',
        updated_at        TEXT NOT NULL,
        UNIQUE (mosaic_id, panel_index)
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_collab_panel_mosaic '
      'ON collaborative_mosaic_panels(mosaic_id);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_collab_panel_assignee '
      'ON collaborative_mosaic_panels(assigned_account_id);',
    );

    // Live co-imaging sessions. The hub tracks combined integration /
    // frame count across all participating rigs; each participant gets a small
    // assigned framing offset so rigs tile the field instead of stacking
    // identically. `shared_target_id` links the longitude hand-off baton.
    db.execute('''
      CREATE TABLE IF NOT EXISTS coimaging_sessions (
        id                TEXT PRIMARY KEY,
        owner_account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        target_name       TEXT NOT NULL,
        center_ra_deg     REAL NOT NULL,
        center_dec_deg    REAL NOT NULL,
        shared_target_id  INTEGER REFERENCES shared_targets(id) ON DELETE SET NULL,
        status            TEXT NOT NULL DEFAULT 'active',
        combined_frames   INTEGER NOT NULL DEFAULT 0,
        combined_integration_seconds REAL NOT NULL DEFAULT 0,
        created_at        TEXT NOT NULL,
        updated_at        TEXT NOT NULL
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_coimaging_owner '
      'ON coimaging_sessions(owner_account_id);',
    );
    db.execute('''
      CREATE TABLE IF NOT EXISTS coimaging_participants (
        id                TEXT PRIMARY KEY,
        session_id        TEXT NOT NULL REFERENCES coimaging_sessions(id)
                            ON DELETE CASCADE,
        account_id        TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        rig_id            TEXT NOT NULL DEFAULT '',
        role              TEXT NOT NULL DEFAULT 'contribute',
        membership_token  TEXT NOT NULL DEFAULT '',
        framing_offset_index INTEGER NOT NULL DEFAULT 0,
        framing_offset_ra_arcsec  REAL NOT NULL DEFAULT 0,
        framing_offset_dec_arcsec REAL NOT NULL DEFAULT 0,
        contributed_frames INTEGER NOT NULL DEFAULT 0,
        contributed_integration_seconds REAL NOT NULL DEFAULT 0,
        joined_at         TEXT NOT NULL,
        updated_at        TEXT NOT NULL,
        UNIQUE (session_id, account_id, rig_id)
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_coimaging_participant_session '
      'ON coimaging_participants(session_id);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_coimaging_participant_account '
      'ON coimaging_participants(account_id);',
    );

    // Per-SESSION longitude-baton claim ("who is imaging now"). Keyed on the
    // session — NOT the cone-merged shared target — so two distinct co-imaging
    // sessions pointed at the same object never collapse onto one baton.
    db.execute('''
      CREATE TABLE IF NOT EXISTS coimaging_batons (
        session_id  TEXT PRIMARY KEY REFERENCES coimaging_sessions(id)
                       ON DELETE CASCADE,
        account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        claim_token TEXT NOT NULL,
        claimed_at  TEXT NOT NULL,
        expires_at  TEXT NOT NULL
      );
    ''');

    // --- Trust, consent, identity (cross-cutting) --------------------------

    // MODERATION: an operator must be able to stop an abusive account without
    // deleting it (which would FK-cascade away its history). `suspended_at` is
    // the live kill switch — [TokenService.resolve] joins it and fails CLOSED on
    // any non-null value, so every unexpired token of a suspended account dies
    // at once. `suspended_reason` carries the operator note for the audit trail.
    // Added via the guarded [_ensureColumn] helper so an existing DB upgrades in
    // place (the original `accounts` CREATE above only seeds a fresh DB).
    _ensureColumn('accounts', 'suspended_at', 'TEXT');
    _ensureColumn('accounts', 'suspended_reason', 'TEXT');

    // CONSENT: the license + per-action consent a contributor granted for ONE
    // shared artifact, recorded BEFORE any bytes are stored (the publish/share
    // gate). `revoked_at` is stamped on retraction so a removed contribution can
    // prove it is no longer consented. `attribution_consent` records whether the
    // contributor wants public credit (false → "Anonymous contributor" in the
    // attribution UI). The `license` CHECK rejects unknown wire names at write
    // time (fail-closed, mirroring `shared_calibration_masters.license`).
    db.execute('''
      CREATE TABLE IF NOT EXISTS consent_records (
        id                  TEXT PRIMARY KEY,
        account_id          TEXT NOT NULL REFERENCES accounts(id)
                              ON DELETE CASCADE,
        artifact_type       TEXT NOT NULL,
        artifact_ref        TEXT NOT NULL,
        license             TEXT NOT NULL DEFAULT 'private'
                              CHECK (license IN
                                ('private','cc0','cc-by','cc-by-sa','cc-by-nc')),
        share_raw_subframes INTEGER NOT NULL DEFAULT 0,
        allow_derivatives   INTEGER NOT NULL DEFAULT 0,
        allow_redistribution INTEGER NOT NULL DEFAULT 0,
        attribution_consent INTEGER NOT NULL DEFAULT 1,
        created_at          TEXT NOT NULL,
        revoked_at          TEXT
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_consent_artifact '
      'ON consent_records(artifact_type, artifact_ref);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_consent_account '
      'ON consent_records(account_id);',
    );

    // The existing additive-sum + raw-subframe ledgers gain the license +
    // consent_id of the consent record that gated each contribution, so a
    // retraction can find and revoke the matching consent and the attribution
    // recompute can read the license. Guarded so existing DBs upgrade in place.
    _ensureColumn('contributions', 'license', 'TEXT');
    _ensureColumn('contributions', 'consent_id', 'TEXT');
    _ensureColumn('raw_subframe_contributions', 'license', 'TEXT');
    _ensureColumn('raw_subframe_contributions', 'consent_id', 'TEXT');

    // The collaborative-mosaic panel + co-imaging participant ledgers gain the
    // same license + consent_id + attribution_consent the mosaic / co-imaging
    // SHARE paths record at upload / contribute time. A panel master streamed
    // into a shared redistributable mosaic — and a co-imaging rig's
    // combined-accounting report — are shares exactly like a tile contribution,
    // so each carries the consent
    // that gated it: the retraction (force-release / panel reset) can revoke the
    // matching consent, and the finalize/close attribution can read the license +
    // honour the contributor's named-vs-anonymous choice. Guarded so existing DBs
    // upgrade in place. `attribution_consent` defaults to 1 (credited) so a row
    // written before the column existed is not retroactively forced anonymous.
    _ensureColumn('collaborative_mosaic_panels', 'license', 'TEXT');
    _ensureColumn('collaborative_mosaic_panels', 'consent_id', 'TEXT');
    _ensureColumn(
      'collaborative_mosaic_panels',
      'attribution_consent',
      'INTEGER NOT NULL DEFAULT 1',
    );
    _ensureColumn('coimaging_participants', 'license', 'TEXT');
    _ensureColumn('coimaging_participants', 'consent_id', 'TEXT');
    _ensureColumn(
      'coimaging_participants',
      'attribution_consent',
      'INTEGER NOT NULL DEFAULT 1',
    );

    // MODERATION ACTIONS: an append-only ledger of every suspend/reinstate with
    // the moderator, the target, the reason, and whether it was auto-flagged by
    // the abuse threshold — the trail an operator reviews when contesting a
    // suspension.
    db.execute('''
      CREATE TABLE IF NOT EXISTS moderation_actions (
        id                TEXT PRIMARY KEY,
        target_account_id TEXT NOT NULL REFERENCES accounts(id)
                            ON DELETE CASCADE,
        moderator_account_id TEXT,
        action            TEXT NOT NULL,
        reason            TEXT,
        auto              INTEGER NOT NULL DEFAULT 0,
        created_at        TEXT NOT NULL
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_moderation_target '
      'ON moderation_actions(target_account_id);',
    );

    // ATTRIBUTION: per-account credit materialized for a finished collaborative
    // artifact (a fused tile, a stitched mosaic, a closed co-imaging session).
    // One row per (artifact, account) — UNIQUE so the additive recordAccepted /
    // recompute upserts are idempotent. `anonymous` mirrors the contributor's
    // attribution_consent so the credit list can render "Anonymous contributor"
    // without leaking the account. Frames/seconds drive the credit ordering.
    db.execute('''
      CREATE TABLE IF NOT EXISTS artifact_attributions (
        id                  TEXT PRIMARY KEY,
        artifact_type       TEXT NOT NULL,
        artifact_ref        TEXT NOT NULL,
        account_id          TEXT NOT NULL REFERENCES accounts(id)
                              ON DELETE CASCADE,
        frames              INTEGER NOT NULL DEFAULT 0,
        integration_seconds REAL NOT NULL DEFAULT 0,
        license             TEXT,
        anonymous           INTEGER NOT NULL DEFAULT 0,
        updated_at          TEXT NOT NULL,
        UNIQUE (artifact_type, artifact_ref, account_id)
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_attribution_artifact '
      'ON artifact_attributions(artifact_type, artifact_ref);',
    );
  }

  /// Add [column] of [type] to [table] only when it is not already present.
  /// Idempotent guarded migration for evolving a table that an older DB created
  /// without the column — `PRAGMA table_info` is the column inventory, and the
  /// `ALTER TABLE ... ADD COLUMN` is skipped when the column already exists (so
  /// re-running is a no-op and a fresh DB that defined the column inline is
  /// untouched). No default is applied beyond SQL NULL, matching how the
  /// collaborative tables treat nullable provenance.
  void _ensureColumn(String table, String column, String type) {
    final cols = db.select('PRAGMA table_info($table);');
    final present = cols.any((r) => r['name'] == column);
    if (present) return;
    db.execute('ALTER TABLE $table ADD COLUMN $column $type;');
  }

  void dispose() => db.dispose();
}
