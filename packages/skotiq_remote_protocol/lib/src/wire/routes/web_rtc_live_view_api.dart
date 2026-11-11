import '../api_route.dart';

enum WebRtcLiveViewApi implements ApiEndpoint {
  rsOffer(
    ApiRoute.post(
      '/api/webrtc/live-view/offer',
      resource: ApiResource.system,
      bucket: ApiBucket.liveView,
    ),
  ),
  rsSessionid(
    ApiRoute.post(
      '/api/webrtc/live-view/ice/<sessionId>',
      resource: ApiResource.system,
      bucket: ApiBucket.liveView,
    ),
  ),
  rs(
    ApiRoute.get(
      '/api/webrtc/live-view/ice/<sessionId>/events',
      resource: ApiResource.system,
      timeout: ApiTimeout.openEnded,
      bucket: ApiBucket.liveView,
    ),
  ),
  rsDelete(
    ApiRoute.delete(
      '/api/webrtc/live-view/<sessionId>',
      resource: ApiResource.system,
      bucket: ApiBucket.liveView,
    ),
  );

  const WebRtcLiveViewApi(this.route);

  @override
  final ApiRoute route;
}
