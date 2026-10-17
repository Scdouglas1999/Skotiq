import 'package:drift/drift.dart';

/// Client-side membership in a live co-imaging session.
///
/// When this rig joins a session at a hub, the hub assigns it a participant
/// slot (a small framing offset so rigs don't all frame identically) and hands
/// back a membership/claim token. The durable local record lets a relaunched
/// host — or a remote companion app — re-render which sessions the rig is in,
/// with what role and framing offset, without a live hub round-trip.
///
/// Identity is `(hubKey, sessionId)` — one membership row per session per hub.
/// [hubKey] is the normalized federation endpoint URL, matching
/// [ConstellationContributions.hubKey] so the two join cleanly. Enum-ish
/// columns (role) are stored as stable text.
///
/// Additive and FK-free: a membership receipt must survive the local deletion
/// or re-fold of any atlas tile it relates to, and the remote session is the
/// source of truth for liveness — [active] is the locally-cached view of it.
@DataClassName('CoImagingSessionRow')
@TableIndex(
  name: 'idx_coimaging_sessions_key',
  unique: true,
  columns: {#hubKey, #sessionId},
)
class CoImagingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Federation endpoint identity — the normalized hub base URL (mirrors
  /// [ConstellationContributions.hubKey]).
  TextColumn get hubKey => text()();

  /// Remote co-imaging session id this rig joined (the hub's
  /// `coimaging_sessions.id`).
  TextColumn get sessionId => text()();

  /// Cached human-readable target identity for offline rehydration.
  TextColumn get targetName => text().nullable()();
  RealColumn get targetRaDeg => real().nullable()();
  RealColumn get targetDecDeg => real().nullable()();

  /// This rig's collaborative role in the session — the wire name of a
  /// `CollaborativeRole` (read / contribute / admin). Defaults to contribute
  /// because joining a co-imaging session is, by definition, to contribute.
  TextColumn get role => text().withDefault(const Constant('contribute'))();

  /// The hub-issued membership / claim token, used to authenticate this rig's
  /// contributions to the session (analogous to the hand-off baton's claim
  /// token). Null until the JOIN completes.
  TextColumn get claimToken => text().nullable()();

  /// The hub-assigned participant slot index (0-based), driving the small
  /// framing offset so participating rigs tile the field instead of stacking
  /// identically (better coverage + walking-noise rejection).
  IntColumn get framingOffsetIndex =>
      integer().withDefault(const Constant(0))();

  /// The assigned framing offset in arcseconds (RA/Dec) the rig nudges its
  /// pointing by. Both default to 0 (the anchor slot).
  RealColumn get framingOffsetRaArcsec =>
      real().withDefault(const Constant(0))();
  RealColumn get framingOffsetDecArcsec =>
      real().withDefault(const Constant(0))();

  /// Running tally of own-light frames / integration this rig has contributed
  /// to the session (cumulative; the hub holds the authoritative combined
  /// total across all participants).
  IntColumn get contributedFrames => integer().withDefault(const Constant(0))();
  RealColumn get contributedIntegrationSeconds =>
      real().withDefault(const Constant(0))();

  /// Locally-cached liveness: whether the rig considers itself an active
  /// participant. Set false on leave / when the hub reports the session closed.
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  DateTimeColumn get joinedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
