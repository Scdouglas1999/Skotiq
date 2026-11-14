import '../api_route.dart';

enum BackupApi implements ApiEndpoint {
  listBackups(
    ApiRoute.get(
      '/api/backup/list',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  createBackup(
    ApiRoute.post(
      '/api/backup/create',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  ),
  restoreBackup(
    ApiRoute.post(
      '/api/backup/restore',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'backup_restore',
    ),
  ),
  autoSaveBackup(
    ApiRoute.post(
      '/api/backup/auto-save',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  ),
  uploadRestoreBackup(
    ApiRoute.post(
      '/api/backup/upload-restore',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'backup_upload_restore',
      maxBodyBytes: ApiBodyLimit.archive,
    ),
  ),
  getBackupMetadata(
    ApiRoute.get(
      '/api/backup/<id>/metadata',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  downloadBackup(
    ApiRoute.get(
      '/api/backup/<id>/download',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      timeout: ApiTimeout.slowRead,
      bucket: ApiBucket.imageDownload,
    ),
  ),
  deleteBackup(
    ApiRoute.delete(
      '/api/backup/<id>',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  );

  const BackupApi(this.route);

  @override
  final ApiRoute route;
}
