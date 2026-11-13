import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import 'settings_provider.dart';
import 'logging_service_provider.dart';

/// Points this process's catalog downloads at the source chosen in Settings >
/// Catalogs. Every role runs it: a host downloads for itself and its clients,
/// and a linked client follows the host's choice for the catalogs it keeps.
final catalogDownloadSourceSyncProvider = Provider<void>((ref) {
  final url = ref.watch(
    appSettingsProvider.select((s) => s.valueOrNull?.catalogBaseUrl),
  );
  if (url == null) return;
  try {
    CatalogManager.instance.setCatalogBaseUrl(url);
  } on ArgumentError catch (e) {
    CatalogManager.instance.setCatalogBaseUrl('');
    ref
        .read(loggingServiceProvider)
        .warning(
          'Catalog download source "$url" is not usable (${e.message}); '
          'downloading from the Skotiq release',
          source: 'CatalogDownloadSource',
        );
  }
});
