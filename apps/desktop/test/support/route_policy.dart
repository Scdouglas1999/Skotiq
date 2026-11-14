/// Policy questions asked by method and path, answered from the declared
/// route table the way the server answers them for a request.
library;

import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_desktop/headless_api/rate_limiting.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:skotiq_remote_protocol/wire.dart';

import '../support/route_policy.dart';

export 'package:skotiq_remote_protocol/wire.dart';

/// The route a request is held to. `WS` asks about the upgrade request.
ApiRoute routeFor(String method, String path) {
  final verb = method.toUpperCase() == 'WS' ? 'GET' : method;
  return apiRouteIndex.policyFor(verb, path.startsWith('/') ? path : '/$path');
}

String requiredAuthScopeNameForEndpoint({
  required String method,
  required String path,
}) => routeFor(method, path).scope.name;

String resourceKeyForEndpoint({required String method, required String path}) =>
    routeFor(method, path).resource.wireName;

class EndpointRateLimit {
  const EndpointRateLimit(this.maxRequests);

  final int maxRequests;
  Duration get window => endpointRateLimitWindow;
}

EndpointRateLimit? endpointRateLimitFor({
  required String method,
  required String path,
}) {
  final max = routeFor(method, path).rate.maxRequestsPerMinute;
  return max == null ? null : EndpointRateLimit(max);
}

String? highRiskAuditActionFor({
  required String method,
  required String path,
}) => routeFor(method, path).audit;

int requestBodyLimitForPath(String path) => routeFor('POST', path).maxBodyBytes;

/// True when any method of [path] is in the high-risk rate tier.
bool isHighRiskControlPath(String path) => const [
  'POST',
  'PUT',
  'DELETE',
].any((method) => routeFor(method, path).rate == ApiRateTier.highRisk);

ApiBucket tokenRouteClassFor({required String method, required String path}) =>
    routeFor(method, path).bucket;

bool isOwnershipRequired({required String method, required String path}) =>
    routeFor(method, path).sessionOwner;

bool allowsPath({
  required HeadlessTokenScope actual,
  required String method,
  required String path,
}) => HeadlessAuthPolicy.allows(actual: actual, route: routeFor(method, path));

bool permitsPath({
  required HeadlessAuthGrant grant,
  required String method,
  required String path,
}) => HeadlessAuthPolicy.permits(grant: grant, route: routeFor(method, path));

RouteCapability capabilityForPath({
  required String method,
  required String path,
}) => HeadlessAuthPolicy.requiredCapabilityFor(routeFor(method, path));

HeadlessTokenScope scopeForPath({
  required String method,
  required String path,
}) => HeadlessAuthPolicy.requiredScopeFor(routeFor(method, path));

Map<String, Object?> scopeDenialBodyForPath({
  required HeadlessAuthGrant grant,
  required String method,
  required String path,
}) => HeadlessAuthPolicy.scopeDenialBody(
  grant: grant,
  route: routeFor(method, path),
);

/// A route declared by a test, for tables that are not the real one.
class TestEndpoint implements ApiEndpoint {
  const TestEndpoint(this.route);

  @override
  final ApiRoute route;
}

final int defaultControlRateLimitMaxRequests =
    ApiRateTier.control.maxRequestsPerMinute!;
final int highRiskControlRateLimitMaxRequests =
    ApiRateTier.highRisk.maxRequestsPerMinute!;
const Duration defaultControlRateLimitWindow = endpointRateLimitWindow;

extension EndpointRateLimiterByPath on EndpointRateLimiter {
  /// [EndpointRateLimiter.check] with the tier of the route [path] resolves to.
  RateLimitDecision checkRequest({
    required String clientKey,
    required String method,
    required String path,
  }) => check(
    clientKey: clientKey,
    method: method,
    path: path,
    tier: routeFor(method, path).rate,
  );
}

class _NoRoutes implements RouteSource {
  const _NoRoutes();

  @override
  Map<ApiEndpoint, Function> get routes => const {};
}

/// Attaches the route context a middleware under test reads, for a pipeline
/// with no routes: reads get the read policy, everything else the command
/// policy.
final Middleware unroutedContext = RouteTable.only(
  const _NoRoutes(),
).resolveMiddleware;
