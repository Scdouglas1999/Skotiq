/// Public aliases for drift-generated entity classes that collide with
/// domain-model classes of the same name in the core barrel.
///
/// The model-layer classes (`CapturedImage` in
/// `src/models/imaging/imaging_models.dart`, `EquipmentProfile` in
/// `src/models/equipment_profile.dart`) keep their canonical names because
/// they are the domain types most code touches. The drift row types are
/// re-exported here under `Db`-prefixed aliases so callers can reach them
/// through the public `package:skotiq_core/skotiq_core.dart` barrel
/// without `src/database/database.dart` bypass imports.
///
library;

import 'database.dart' as drift;

/// Drift row type for the `captured_images` table.
///
/// Distinct from the in-memory domain model `CapturedImage`
/// (`src/models/imaging/imaging_models.dart`) which carries `ExposureSettings`
/// and `ImageStats` value objects rather than flat column fields.
typedef DbCapturedImage = drift.CapturedImage;

/// Drift row type for the `equipment_profiles` table.
///
/// Distinct from the freezed domain model `EquipmentProfile`
/// (`src/models/equipment_profile.dart`) which uses string IDs and contains
/// computed/extension properties not persisted to the database.
typedef DbEquipmentProfile = drift.EquipmentProfile;

/// Drift row type for the `targets` table.
///
/// Distinct from the domain `Target` types used by sequence nodes and the
/// scheduler. Consumers that read raw target rows from the database (e.g.
/// `searchTargets` results in the quick-start wizard, smart-night drafts)
/// reach this alias through the public barrel so the raw Drift `Target`
/// class can stay hidden from the barrel without forcing an
/// `// ignore: implementation_imports`.
typedef DbTarget = drift.Target;
