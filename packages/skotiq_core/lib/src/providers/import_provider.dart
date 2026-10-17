import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../backend/network_backend.dart';
import 'backend_provider.dart';
import '../services/import/astrobin_importer.dart';
import '../services/import/sequence_importer.dart';

/// Provides the singleton [SequenceImporter] used by the UI.
final sequenceImporterProvider = Provider<SequenceImporter>((ref) {
  final backend = ref.watch(backendProvider);
  return SequenceImporter(
    astrobin: AstrobinImporter(
      catalog: CatalogSearchLookup((designation) async {
        if (backend is NetworkBackend) {
          final response = await backend.planetariumCatalogSearch(designation);
          final rawResults = response['results'];
          if (rawResults is! List) {
            throw const FormatException(
              'Remote catalog search response is missing its results list.',
            );
          }
          return rawResults
              .map((raw) {
                if (raw is! Map) {
                  throw const FormatException(
                    'Remote catalog search result is not a JSON object.',
                  );
                }
                final row = raw.cast<String, dynamic>();
                final name = (row['name'] as String?)?.trim() ?? '';
                final catalogId = (row['catalogId'] as String?)?.trim() ?? '';
                final raHours = (row['raHours'] as num?)?.toDouble();
                final dec = (row['dec'] as num?)?.toDouble();
                if ((name.isEmpty && catalogId.isEmpty) ||
                    raHours == null ||
                    dec == null) {
                  throw const FormatException(
                    'Remote catalog search result is missing identity or '
                    'coordinates.',
                  );
                }
                return CatalogLookupResult(
                  canonicalName: name.isNotEmpty ? name : catalogId,
                  raHours: raHours,
                  decDegrees: dec,
                  identifiers: [
                    if (catalogId.isNotEmpty) catalogId,
                    if (name.isNotEmpty) name,
                  ],
                );
              })
              .toList(growable: false);
        }

        final manager = CatalogManager.instance;
        if (!manager.isInitialized) return const <CatalogLookupResult>[];
        final results = await manager.search(designation);
        return results
            .map(
              (result) => CatalogLookupResult(
                canonicalName: result.name.isNotEmpty
                    ? result.name
                    : result.catalogId,
                raHours: result.ra / 15.0,
                decDegrees: result.dec,
                identifiers: [result.catalogId, result.name],
              ),
            )
            .toList(growable: false);
      }),
    ),
  );
});
