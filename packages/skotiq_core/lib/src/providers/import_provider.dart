import 'host_role.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/import/astrobin_importer.dart';
import '../services/import/sequence_importer.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'sesame_name_resolver_provider.dart';

/// Provides the singleton [SequenceImporter] used by the UI.
/// The installed catalog a designation is looked up in: this machine's, or
/// the linked host's.
final _installedCatalogLookupProvider = hostRoleProvider<CatalogLookup>(
  here: (_) => ResolverCatalogLookup(() => CatalogManager.instance.dsos.load()),
  linked: (_, host) => CatalogSearchLookup((designation) async {
          final response = await host.planning.planetariumCatalogSearch(designation);
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
        }),
);

final sequenceImporterProvider = Provider<SequenceImporter>((ref) {
  // Astrobin subjects resolve by exact designation or name only, against the
  // installed catalog, then SIMBAD.
  final primary = ref.watch(_installedCatalogLookupProvider);
  return SequenceImporter(
    astrobin: AstrobinImporter(
      catalog: OnlineFallbackLookup(
        primary: primary,
        online: ref.watch(sesameNameResolverProvider),
      ),
    ),
  );
});
