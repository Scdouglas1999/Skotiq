import 'package:drift/drift.dart' show Value;
import 'package:skotiq_astro/skotiq_astro.dart';

import '../database/database.dart' as db;
import '../utils/logging_service.dart';

/// [target] with the object type it reads: the deep-sky catalog's type for
/// the object its catalog id, else its name (a designation or a common name
/// the catalog lists), designates, so a catalog update reclassifies targets
/// saved before it. A target no name identifies takes the type of the object
/// whose catalogued size holds its position ([DsoDesignations.containing])
/// when it has no type of its own; a position the user entered outside every
/// object keeps the type stored with it.
db.DbTarget withCatalogObjectType(db.DbTarget target, DsoDesignations catalog) {
  final byName = catalog.ofTarget(
    catalogId: target.catalogId,
    name: target.name,
  );
  final stored = target.objectType;
  final hasStoredType = stored != null && stored.trim().isNotEmpty;
  final object =
      byName ??
      (hasStoredType
          ? null
          : catalog.containing(raHours: target.ra, decDegrees: target.dec));
  if (object == null) return target;
  final type = object.type.displayName;
  if (type == target.objectType) return target;
  return target.copyWith(objectType: Value(type));
}

/// The catalog object type for a target named [name] at [raHours],
/// [decDegrees] ([DsoDesignations.ofTarget]: its catalog id, its name or a
/// common name, else the object its position is in), or null when none.
Future<String?> catalogObjectTypeFor({
  required String name,
  required double raHours,
  required double decDegrees,
  String? catalogId,
  LoggingService? logging,
}) async {
  final catalog = await installedDsoDesignations(logging);
  return catalog
      .ofTarget(
        catalogId: catalogId,
        name: name,
        raHours: raHours,
        decDegrees: decDegrees,
      )
      ?.type
      .displayName;
}

/// [targets], each with the object type it reads ([withCatalogObjectType])
/// from the installed deep-sky catalog.
Future<List<db.DbTarget>> withCatalogObjectTypes(
  List<db.DbTarget> targets,
  LoggingService logging,
) async {
  if (targets.isEmpty) return targets;
  final catalog = await installedDsoDesignations(logging);
  return [for (final target in targets) withCatalogObjectType(target, catalog)];
}

/// The installed deep-sky catalog by designation. Empty with no catalog
/// installed; a catalog that cannot be read is logged (to [logging], else the
/// app log) and gives none, so targets read with their stored types.
Future<DsoDesignations> installedDsoDesignations([
  LoggingService? logging,
]) async {
  final manager = CatalogManager.instance;
  if (!manager.isInitialized) return DsoDesignations.empty;
  try {
    if (!(await manager.status(SkyCatalog.dso)).isInstalled) {
      return DsoDesignations.empty;
    }
    return await manager.dsos.designations();
  } catch (e) {
    const message =
        'The deep-sky catalog could not be read, so targets show the object '
        'types saved with them';
    if (logging != null) {
      logging.error('$message: $e', source: 'CatalogTargetTypes');
    } else {
      Log.error('$message: $e', source: 'CatalogTargetTypes');
    }
    return DsoDesignations.empty;
  }
}
