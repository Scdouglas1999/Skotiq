part of '../network_backend.dart';

/// The star and object catalogs installed on a linked imaging host.
final class HostCatalogs {
  HostCatalogs(this._host);

  final NetworkBackend _host;

  /// POST /api/catalog/download. Returns the job handle; the actual
  /// download runs in the background and progress is broadcast as
  /// `catalog`-category events on the WS stream.
  Future<RemoteJob> downloadCatalog(String name) async {
    final response = await _host._post(CatalogApi.download, body: {'name': name});
    return RemoteJob.fromJson(response, fallbackOperation: 'catalog.download');
  }

  /// GET /api/catalog/status. Returns the on-disk state of every known
  /// catalog on the *server*. The mobile/desktop remote client surfaces
  /// this in the catalog management UI so a freshly-imaged server can be
  /// detected ("plate-solve will fail until you download a star catalog").
  Future<RemoteCatalogStatusResponse> getCatalogStatus() async {
    final response = await _host._get(CatalogApi.status);
    return RemoteCatalogStatusResponse.fromJson(response);
  }

  /// GET /api/catalog/available. Returns the manifest of catalogs the
  /// server knows how to download. Cached server-side for 1 hour.
  Future<List<RemoteAvailableCatalog>> listAvailableCatalogs() async {
    final response = await _host._get(CatalogApi.available);
    return _rowsFromJson(
      response['available'],
      RemoteAvailableCatalog.fromJson,
    );
  }

  /// POST /api/catalog/reload. Drops the server's cached catalog loaders
  /// so subsequent searches re-parse the on-disk files.
  Future<void> reloadCatalogs() async {
    await _host._post(CatalogApi.reload);
  }

  /// DELETE /api/catalog/{name}.
  Future<void> uninstallCatalog(String name) async {
    await _host._delete(CatalogApi.delete, path: {'name': name});
  }

  /// POST /api/catalog/verify. Recomputes SHA-256 over every (or one)
  /// installed catalog and returns the per-name verification result.
  Future<Map<String, RemoteCatalogVerifyResult>> verifyCatalog({
    String? name,
  }) async {
    final response = await _host._post(
      CatalogApi.verify,
      body: name == null ? null : {'name': name},
    );
    final verified = response['verified'];
    if (verified is! Map) {
      throw StateError(
        'Malformed /catalog/verify response: missing `verified` field',
      );
    }
    return verified.map((key, value) {
      if (value is! Map) {
        throw StateError('Malformed verify result for `$key`: expected object');
      }
      return MapEntry(
        key.toString(),
        RemoteCatalogVerifyResult.fromJson(value.cast<String, dynamic>()),
      );
    });
  }
}
