/// Schema documentation for the v58 Darkroom tables: `recipes`,
/// `darkroom_jobs`, `delivery_targets`, and `delivery_journal`.
///
/// These tables are managed with raw `CREATE TABLE` statements (see
/// `database.dart` migration v58 — the `_createDarkroomTables()` helper) and
/// accessed through plain DAO classes (`RecipesDao`, `DarkroomJobsDao`,
/// `DeliveryTargetsDao`, `DeliveryJournalDao`) that read/write via
/// `customSelect` / `customInsert` / `customStatement`, rather than drift
/// `Table` classes. This follows the dominant v27+ convention
/// (`integrated_masters`, `mosaic_projects`, `campaigns`): adding them does not
/// require a `melos run generate` codegen pass.
///
/// Every enum-valued column carries a `CHECK` constraint listing its legal wire
/// strings, so a value outside the set is storage corruption rather than an
/// older format. The model `fromWire` parsers throw
/// `DarkroomWireFormatException` on such a value instead of defaulting — a
/// `failed` job silently read back as `queued` would re-run work whose data is
/// already gone.
///
/// Timestamps are unix seconds UTC, matching the raw-DDL convention across
/// `integrated_masters` / `mosaic_projects` / `campaigns`.
///
/// ---
///
/// `recipes` — one row per non-destructive operation stack over a linear
/// master. A branch is a row pointing at its parent.
///
/// Columns:
///   id                INTEGER PRIMARY KEY AUTOINCREMENT
///   target_id         INTEGER  (FK targets.id,            ON DELETE SET NULL)
///   session_id        INTEGER  (FK imaging_sessions.id,   ON DELETE SET NULL)
///   master_id         INTEGER  (FK integrated_masters.id, ON DELETE SET NULL)
///   base_master_path  TEXT NOT NULL   (linear master FITS this replays over)
///   name              TEXT NOT NULL DEFAULT ''   (branch label)
///   steps_json        TEXT NOT NULL DEFAULT '[]' (ordered op stack)
///   created_by        TEXT NOT NULL DEFAULT 'autopilot'  ('autopilot'|'user')
///   draft_notes_json  TEXT NOT NULL DEFAULT '[]'  (v59; composition account)
///   parent_recipe_id  INTEGER  (FK recipes.id, ON DELETE RESTRICT)
///   divergence_index  INTEGER  (index into the PARENT's steps; null for roots)
///   schema_version    INTEGER NOT NULL DEFAULT 1  (steps_json envelope format)
///   created_at        INTEGER NOT NULL
///   updated_at        INTEGER NOT NULL
///
/// CHECKs: `created_by IN ('autopilot','user')`; `schema_version >= 1`;
/// `divergence_index IS NULL OR divergence_index >= 0`; and the branch
/// coherence pair — a divergence index requires a parent, and a parent
/// requires a divergence index.
///
/// Indexes: target_id, session_id, master_id, parent_recipe_id,
/// base_master_path, created_at.
///
/// `draft_notes_json` (v59) is the composing pass's own account: a JSON array
/// of `{opId, outcome, reason}` objects, one per operation the registry decided
/// about, in the order it decided. It is the record the step list cannot carry
/// — an operation that was left OUT has no card to say why — and it persists so
/// that reopening a draft, or reloading it, shows the same reasons the night
/// report holds. A recipe a human wrote step by step carries `'[]'`.
/// [RecipesDao.draftNotesOf] / [RecipesDao.setDraftNotes] own the encoding.
///
/// The identity columns are the ones the post-session flow already uses:
/// `target_id` is what `integrated_masters.target_id` carries, and `session_id`
/// is the `imaging_sessions.id` the dawn coordinator reads from
/// `SequenceTerminalRunResult.dbSessionId` (the live session id is already
/// nulled by `endSession` before the terminal result publishes).
///
/// PARENT DELETE POLICY — restrict, never re-parent. `parent_recipe_id` is
/// `ON DELETE RESTRICT`, and `RecipesDao.deleteRecipe` refuses a parent with
/// children by throwing `RecipeHasChildrenException` before SQLite is asked.
/// A branch is defined by BOTH its parent and the `divergence_index` into that
/// parent's step list; silently re-parenting to the grandparent would leave the
/// index pointing into a step list the row never diverged from, so the branch
/// would keep rendering while describing a lineage that never happened.
/// `RecipesDao.deleteRecipeSubtree` is the explicit destructive alternative.
///
/// ---
///
/// `darkroom_jobs` — the durable dawn-job queue. The in-memory `JobManager`
/// (`apps/desktop/lib/headless_api/`) is purged at 24 h, cleared on server
/// stop, and absent from the GUI path; this table is what survives safing, a
/// force quit, and the 3am power cut.
///
/// Columns:
///   id           INTEGER PRIMARY KEY AUTOINCREMENT
///   session_id   INTEGER  (FK imaging_sessions.id, ON DELETE CASCADE)
///   kind         TEXT NOT NULL DEFAULT 'dawn'    ('dawn'|'manual')
///   state        TEXT NOT NULL DEFAULT 'queued'
///                ('queued'|'running'|'cancelled'|'done'|'failed')
///   progress     REAL NOT NULL DEFAULT 0.0   (0.0 .. 1.0)
///   note         TEXT   (current step while running; recovery note after a
///                        crash reset)
///   error_text   TEXT   (why it failed or was cancelled)
///   attempts     INTEGER NOT NULL DEFAULT 0  (starts, including restarts)
///   created_at   INTEGER NOT NULL
///   started_at   INTEGER
///   finished_at  INTEGER
///
/// CHECKs: the `kind` and `state` value sets; `progress BETWEEN 0.0 AND 1.0`;
/// `attempts >= 0`.
///
/// Indexes: (state, created_at), session_id, created_at.
///
/// CRASH RECOVERY CONTRACT. A row is only `running` while a live executor in
/// THIS process holds it — that executor state is in memory, so nothing can
/// still be running at the moment the database opens. Any `running` row at open
/// is residue from a process that died. `beforeOpen` therefore re-queues every
/// such row, stamping `note` with the recovery statement and clearing
/// `started_at`; `progress` is left at its last value so the report can say how
/// far the dead run got. This mirrors the `sequence_runs` interrupted-run
/// reconciliation in the same hook.
///
/// A job whose `attempts` has already reached `kDarkroomJobMaxAttempts` is
/// moved to `failed` instead of re-queued, with `error_text` saying so: a job
/// that kills the process must not re-queue itself forever.
///
/// ---
///
/// `delivery_targets` — where the night's artifacts go. One row per configured
/// destination.
///
/// Columns:
///   id            INTEGER PRIMARY KEY AUTOINCREMENT
///   name          TEXT NOT NULL              (operator-facing, e.g. office-pc)
///   kind          TEXT NOT NULL   ('watched_folder'|'sftp'|'peer')
///   config_json   TEXT NOT NULL DEFAULT '{}' (NON-SECRET transport config)
///   enabled       INTEGER NOT NULL DEFAULT 1 (0/1)
///   content_json  TEXT NOT NULL DEFAULT '[]' (per-destination selection)
///   secret_ref    TEXT   (SecretsStore field key holding this destination's
///                         key material, or null when it needs none)
///   created_at    INTEGER NOT NULL
///   updated_at    INTEGER NOT NULL
///
/// CHECKs: the `kind` value set; `enabled IN (0,1)`.
///
/// Indexes: (enabled, kind), name.
///
/// NO SECRETS IN `config_json`. That column is plaintext in the profile
/// database, which rides export and backup, so an SFTP password written there
/// leaves the machine with the backup. Key material belongs in `SecretsStore`
/// (`services/notification/secrets_store.dart`) — the keyring-backed store that
/// already holds the WebDAV password (`SecretField.cloudSyncPassword`), the S3
/// secret key, and the TNS API key. `secret_ref` names the keyring entry;
/// reading it is the delivery service's job, in a later workstream.
/// `DeliveryTargetsDao` enforces the rule on every write via
/// `assertNoSecretsInConfig`, which throws `DeliveryConfigSecretException`.
///
/// `content_json` is a JSON array of `ArtifactContent` wire strings, always
/// written in enum declaration order, so the same selection serializes to the
/// same bytes however the caller built the set.
///
/// ---
///
/// `delivery_journal` — one row per (destination, job, file): what was sent,
/// how big it was, its checksum, and how it ended.
///
/// Columns:
///   id            INTEGER PRIMARY KEY AUTOINCREMENT
///   target_id     INTEGER NOT NULL (FK delivery_targets.id, ON DELETE CASCADE)
///   job_id        INTEGER NOT NULL (FK darkroom_jobs.id,    ON DELETE CASCADE)
///   file_path     TEXT NOT NULL
///   bytes         INTEGER NOT NULL DEFAULT 0
///   checksum      TEXT
///   state         TEXT NOT NULL DEFAULT 'retrying'
///                 ('delivered'|'failed'|'retrying')
///   attempts      INTEGER NOT NULL DEFAULT 0
///   last_error    TEXT
///   created_at    INTEGER NOT NULL
///   updated_at    INTEGER NOT NULL
///   delivered_at  INTEGER
///   UNIQUE(target_id, job_id, file_path)   (the upsert-on-retry identity)
///
/// CHECKs: the `state` value set; `attempts >= 0`; `bytes >= 0`.
///
/// Indexes: (target_id, state), job_id, (state, updated_at).
///
/// `job_id` is NOT NULL: every delivery belongs to a run, including an operator
/// "process tonight now" (which queues a `manual` job). That keeps the journal
/// identity a plain three-column UNIQUE — a nullable job id would need NULL-
/// tolerant partial indexes, and `ON DELETE SET NULL` could then collapse two
/// distinct rows onto the same key and make a job delete fail.
///
/// Retry is an UPSERT on that identity, not an append: one row per file per run
/// carries the running `attempts` count and the latest `last_error`, so the
/// morning report reads a file's outcome without folding a history.
/// `last_error` is retained after a later success so the report can say the
/// delivery recovered.
library;
