import 'package:drift/drift.dart';

import 'captured_images.dart';
import 'imaging_sessions.dart';

/// Persisted Night Narrator events — the durable backing store for the
/// session-long insight feed. One row per accepted event (the engine has
/// already applied dedupe + cooldown before anything lands here).
///
/// Follows the same nullable-reference convention as the science tables
/// (`tables/science.dart`): both [sessionId] and [capturedImageId] are nullable
/// so standalone (sessionless) captures and events with no triggering frame are
/// first-class. Enum-ish columns ([category], [severity]) are stored as their
/// stable `.name` text so a forward-compatible reader degrades gracefully.
@DataClassName('NarratorEventRow')
@TableIndex(name: 'idx_narrator_events_session', columns: {#sessionId})
@TableIndex(name: 'idx_narrator_events_image', columns: {#capturedImageId})
@TableIndex(name: 'idx_narrator_events_timestamp', columns: {#timestamp})
@TableIndex(
  name: 'idx_narrator_events_dedupe',
  columns: {#sessionId, #dedupeKey},
)
class NarratorEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId => integer().nullable().references(
    ImagingSessions,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get capturedImageId => integer().nullable().references(
    CapturedImages,
    #id,
    onDelete: KeyAction.setNull,
  )();

  DateTimeColumn get timestamp => dateTime().withDefault(currentDateAndTime)();

  /// Stable event id, e.g. `discovery.moving_object`.
  TextColumn get eventType => text()();

  /// `discovery` | `milestone` | `conditions` | `equipment` | `quality`.
  TextColumn get category => text()();

  /// `celebrate` | `success` | `info` | `warning` | `critical`.
  TextColumn get severity => text()();

  /// One sentence, plain language, with concrete numbers.
  TextColumn get headline => text()();

  /// 1–2 sentences: what it means + what to do.
  TextColumn get body => text().nullable()();

  /// Typed micro-visualization payload (see [NarratorEvidence]).
  TextColumn get evidenceJson => text().nullable()();

  /// Engine-level dedupe / cooldown key.
  TextColumn get dedupeKey => text()();

  /// Discoveries pin to the top of feeds.
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
}
