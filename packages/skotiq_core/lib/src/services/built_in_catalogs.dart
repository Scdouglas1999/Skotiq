import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

/// Asset key of the OpenNGC copy that ships in every build (see
/// `assets/catalogs/README.md`).
const String builtInDeepSkyCatalogAsset =
    'packages/skotiq_core/assets/catalogs/NGC.csv';

/// The catalogs that ship inside the app, for [CatalogManager.initialize].
///
/// OpenNGC is small (4 MB), so Messier, NGC and IC names resolve and the sky
/// shows deep-sky objects offline from the first start. The HYG star catalog
/// (34 MB) stays a download.
final Map<SkyCatalog, Future<List<int>> Function()> builtInCatalogs = {
  SkyCatalog.dso: () async {
    final data = await rootBundle.load(builtInDeepSkyCatalogAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  },
};

/// Attribution and license of the built-in catalog data.
const String builtInCatalogNoticeAsset =
    'packages/skotiq_core/assets/catalogs/NOTICE.txt';

bool _catalogLicensesListed = false;

/// Lists the built-in catalog data on Flutter's licenses page, next to the
/// packages. Calling it again adds nothing.
void listBuiltInCatalogLicenses() {
  if (_catalogLicensesListed) return;
  _catalogLicensesListed = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'OpenNGC (catalog data)',
    ], await rootBundle.loadString(builtInCatalogNoticeAsset));
  });
}
