import 'package:drift/drift.dart' show Value;
import 'package:skotiq_astro/skotiq_astro.dart';

import '../database/database.dart' as db;
import '../utils/logging_service.dart';

/// [target] with the object type it reads: the deep-sky catalog's type for
/// the object its catalog id, else its name, designates, so a catalog
/// update reclassifies targets saved before it. A target no designation
/// identifies (a position the user entered, a mosaic panel) keeps the type
/// stored with it.
db.DbTarget withCatalogObjectType(db.DbTarget target, DsoDesignations catalog) {
  final object = catalog.ofTarget(
    catalogId: target.catalogId,
    name: target.name,
  );
  if (object == null) return target;
  final type = object.type.displayName;
  if (type == target.objectType) return target;
  return target.copyWith(objectType: Value(type));
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
/// installed; a catalog that cannot be read is logged and gives none, so
/// targets read with their stored types.
Future<DsoDesignations> installedDsoDesignations(LoggingService logging) async {
  final manager = CatalogManager.instance;
  if (!manager.isInitialized) return DsoDesignations.empty;
  try {
    if (!(await manager.status(SkyCatalog.dso)).isInstalled) {
      return DsoDesignations.empty;
    }
    return await manager.dsos.designations();
  } catch (e) {
    logging.error(
      'The deep-sky catalog could not be read, so targets show the object '
      'types saved with them: $e',
      source: 'CatalogTargetTypes',
    );
    return DsoDesignations.empty;
  }
}
