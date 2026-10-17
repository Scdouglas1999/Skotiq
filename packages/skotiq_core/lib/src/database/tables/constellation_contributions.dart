import 'package:drift/drift.dart';

/// Per-(hub, tile) federation receipts, the record that keeps contributing and
/// pulling idempotent: a per-tile contribution high-water so re-contributing a
/// field ships only the new night, a per-tile pulled-depth high-water so
/// re-pulling an unchanged tile is a no-op, and the joined-target row a
/// relaunched host rehydrates from. The persisted [contributionId] is the
/// remote receipt id the privacy "Retract" action needs.
///
/// Identity is `(hubKey, tileId, healpixOrder)` — one receipt per tile per hub.
/// [hubKey] is the federation endpoint identity (a normalized hub base URL); the
/// service normalizes scheme+host+port before using it so a cosmetic URL change
/// (http/https, trailing slash, mDNS vs IP) does not orphan receipts.
///
/// Enum-ish/text columns are stored as stable text to match the convention in
/// `tables/sky_atlas_tables.dart` / `tables/narrator_events.dart`. This table is
/// intentionally additive and never references the atlas tables by FK: a deleted
/// or re-folded tile must not cascade-drop a federation receipt that still has a
/// live remote `contributionId`.
@DataClassName('ConstellationContributionRow')
@TableIndex(
  name: 'idx_constellation_contributions_key',
  unique: true,
  columns: {#hubKey, #tileId, #healpixOrder},
)
class ConstellationContributions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Federation endpoint identity — the normalized hub base URL.
  TextColumn get hubKey => text()();

  /// HEALPix NESTED pixel id this receipt is for.
  IntColumn get tileId => integer()();

  /// HEALPix order [tileId] was computed at (mirrors the atlas tables so a
  /// future order change is detectable rather than silently mis-addressing).
  IntColumn get healpixOrder => integer()();

  // Contribution high-water (true-delta export anchor)

  /// Anchor timestamp for the next `exportDelta(since:)` — the fold time of the
  /// newest own-light fold already shipped to this hub. Null = nothing shipped
  /// yet (anchor falls back to epoch, i.e. the first contribution ships all
  /// post-epoch own-light folds).
  DateTimeColumn get lastContributedAt => dateTime().nullable()();

  /// ISO fold label of the newest fold shipped (mirrors the fold-label scheme
  /// `capturedAt.toIso8601String()` used at fold time) — the human-readable
  /// twin of [lastContributedAt], retained so the export anchor can be matched
  /// against per-fold labels without re-deriving it from a timestamp.
  TextColumn get lastContributedLabel => text().nullable()();

  /// Remote receipt id returned by the hub for this tile's contribution.
  /// Unblocks the privacy "Retract" action (subtract exactly what was shipped).
  ///
  /// CONSENT/LICENSE: the AUTHORITATIVE consent + license record for a
  /// contribution lives on the hub (`consent_records`, joined to the hub's
  /// contribution row by `consent_id`), recorded BEFORE any bytes are stored and
  /// stamped `revoked_at` on retraction. The client transmits the user's license
  /// + attribution-credit choice on every share (see
  /// `ConstellationService.contributeTarget`/`contributeRawSubs` →
  /// `ConstellationClient.pushTile`/`pushSubframe`), and this row's
  /// [contributionId] maps back to that authoritative hub-side consent. The
  /// local receipt therefore deliberately does NOT mirror a `license` column —
  /// the consent contract is enforced + retained server-side, where it cannot be
  /// edited away by a local DB tamper, and the client reads it back via the
  /// `/v1/attribution` + hub receipt rather than trusting a local copy.
  TextColumn get contributionId => text().nullable()();

  /// Running tally of own-light frames / integration shipped to this hub for
  /// this tile (cumulative across contributions).
  IntColumn get contributedFrames => integer().withDefault(const Constant(0))();
  RealColumn get contributedIntegrationSeconds =>
      real().withDefault(const Constant(0))();

  // Pull high-water (re-pull idempotency)

  /// Community depth last pulled for this tile, as advertised by the hub. A
  /// re-pull whose advertised frames equal this is a no-op (the overlay already
  /// holds exactly that snapshot). Null = never pulled.
  IntColumn get lastPulledFrames => integer().nullable()();
  RealColumn get lastPulledIntegrationSeconds => real().nullable()();
  DateTimeColumn get lastPulledAt => dateTime().nullable()();

  // Co-imaging session link

  /// The live co-imaging session this tile's contributions belong to, if
  /// any — the hub's `coimaging_sessions.id`, mirrored locally so a swarm
  /// contribution receipt can be attributed to a coordinated session rather
  /// than a one-off async contribution. Null for a plain (non-session) tile
  /// contribution. The session's own membership row lives in
  /// [CoImagingSessions], keyed by the same `(hubKey, sessionId)`.
  TextColumn get sessionId => text().nullable()();

  // Join rehydration

  /// Whether the user has joined the target this tile belongs to on this hub.
  BoolColumn get joined => boolean().withDefault(const Constant(false))();
  TextColumn get targetName => text().nullable()();
  RealColumn get targetRaDeg => real().nullable()();
  RealColumn get targetDecDeg => real().nullable()();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
