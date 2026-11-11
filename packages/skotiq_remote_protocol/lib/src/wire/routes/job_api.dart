import '../api_route.dart';

enum JobApi implements ApiEndpoint {
  listJobs(ApiRoute.get('/api/jobs', resource: ApiResource.system)),
  getJob(ApiRoute.get('/api/jobs/<jobId>', resource: ApiResource.system)),
  cancelJob(
    ApiRoute.post('/api/jobs/<jobId>/cancel', resource: ApiResource.system),
  ),
  purgeJob(ApiRoute.delete('/api/jobs/<jobId>', resource: ApiResource.system));

  const JobApi(this.route);

  @override
  final ApiRoute route;
}
