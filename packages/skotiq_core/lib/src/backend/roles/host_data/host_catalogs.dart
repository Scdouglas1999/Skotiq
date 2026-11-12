import '../../network_backend.dart';

/// The star and object catalogs installed on a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostCatalogs {
  Future<RemoteJob> downloadCatalog(String name);

  Future<RemoteCatalogStatusResponse> getCatalogStatus();

  Future<List<RemoteAvailableCatalog>> listAvailableCatalogs();

  Future<void> reloadCatalogs();

  Future<void> uninstallCatalog(String name);

  Future<Map<String, RemoteCatalogVerifyResult>> verifyCatalog({
    String? name,
  });
}
