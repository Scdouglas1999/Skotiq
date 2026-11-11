import '../api_route.dart';

enum SequenceManagementApi implements ApiEndpoint {
  getAllSequences(
    ApiRoute.get('/api/sequence-management/list', resource: ApiResource.system),
  ),
  listFullSequences(
    ApiRoute.get(
      '/api/sequence-management/list-full',
      resource: ApiResource.system,
    ),
  ),
  listFullTemplates(
    ApiRoute.get(
      '/api/sequence-management/templates-full',
      resource: ApiResource.system,
    ),
  ),
  saveFullSequence(
    ApiRoute.post(
      '/api/sequence-management/save-full',
      resource: ApiResource.system,
    ),
  ),
  listSequenceSummaries(
    ApiRoute.get(
      '/api/sequence-management/summaries',
      resource: ApiResource.system,
    ),
  ),
  getVersion(
    ApiRoute.get(
      '/api/sequence-management/versions/<versionId>',
      resource: ApiResource.system,
    ),
  ),
  getFullSequence(
    ApiRoute.get(
      '/api/sequence-management/<id>/full',
      resource: ApiResource.system,
    ),
  ),
  getAllTemplates(
    ApiRoute.get(
      '/api/sequence-management/templates',
      resource: ApiResource.system,
    ),
  ),
  getSequenceById(
    ApiRoute.get('/api/sequence-management/<id>', resource: ApiResource.system),
  ),
  getNodesForSequence(
    ApiRoute.get(
      '/api/sequence-management/<id>/nodes',
      resource: ApiResource.system,
    ),
  ),
  getChildNodes(
    ApiRoute.get(
      '/api/sequence-management/<id>/nodes/<parentNodeId>/children',
      resource: ApiResource.system,
    ),
  ),
  listVersions(
    ApiRoute.get(
      '/api/sequence-management/<id>/versions',
      resource: ApiResource.system,
    ),
  ),
  createSequence(
    ApiRoute.post('/api/sequence-management', resource: ApiResource.system),
  ),
  updateSequence(
    ApiRoute.put('/api/sequence-management/<id>', resource: ApiResource.system),
  ),
  deleteSequence(
    ApiRoute.delete(
      '/api/sequence-management/<id>',
      resource: ApiResource.system,
    ),
  ),
  duplicateSequence(
    ApiRoute.post(
      '/api/sequence-management/<id>/duplicate',
      resource: ApiResource.system,
    ),
  ),
  setTags(
    ApiRoute.put(
      '/api/sequence-management/<id>/tags',
      resource: ApiResource.system,
    ),
  ),
  toggleFavorite(
    ApiRoute.post(
      '/api/sequence-management/<id>/favorite',
      resource: ApiResource.system,
    ),
  ),
  snapshotVersion(
    ApiRoute.post(
      '/api/sequence-management/<id>/versions',
      resource: ApiResource.system,
    ),
  ),
  createNode(
    ApiRoute.post(
      '/api/sequence-management/<id>/nodes',
      resource: ApiResource.system,
    ),
  ),
  updateNode(
    ApiRoute.put(
      '/api/sequence-management/nodes/<nodeId>',
      resource: ApiResource.system,
    ),
  ),
  deleteNode(
    ApiRoute.delete(
      '/api/sequence-management/nodes/<nodeId>',
      resource: ApiResource.system,
    ),
  ),
  reorderNodes(
    ApiRoute.post(
      '/api/sequence-management/<id>/reorder',
      resource: ApiResource.system,
    ),
  ),
  setNodeEnabled(
    ApiRoute.post(
      '/api/sequence-management/nodes/<nodeId>/enabled',
      resource: ApiResource.system,
    ),
  );

  const SequenceManagementApi(this.route);

  @override
  final ApiRoute route;
}
