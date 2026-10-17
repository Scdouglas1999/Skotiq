/// Model barrel for the 7.0 Darkroom data layer: the non-destructive recipe
/// record, the durable dawn-job queue entry, and the delivery destination +
/// journal records.
///
/// The tables behind these are raw DDL (`recipes`, `darkroom_jobs`,
/// `delivery_targets`, `delivery_journal`) documented in
/// `database/tables/darkroom_tables.dart` and reached through the plain
/// `RecipesDao` / `DarkroomJobsDao` / `DeliveryTargetsDao` /
/// `DeliveryJournalDao`.
library;

export 'darkroom_job.dart';
export 'delivery.dart';
export 'recipe.dart';
