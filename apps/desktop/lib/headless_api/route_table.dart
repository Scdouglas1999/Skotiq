/// Binds the declared remote API routes to their handlers and sends each
/// request to the route it matches.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart' show Router;
import 'package:skotiq_remote_protocol/wire.dart';

/// A handler class: the routes it serves and the method behind each.
///
/// A handler takes the request, followed by one `String` per path parameter
/// of its route.
abstract interface class RouteSource {
  Map<ApiEndpoint, Function> get routes;
}

/// What the server knows about a request once its route is found. The
/// middleware reads the policy from here instead of classifying the path.
class RouteContext {
  const RouteContext(this.resolution, this.policy);

  final ApiRouteResolution resolution;

  /// The matched route, or for a request that matches none, the policy it is
  /// held to until it is refused: see [ApiRouteIndex.policyFor].
  final ApiRoute policy;

  bool get isWebSocket => policy.method == ApiMethod.ws;
  bool get isPublic => policy.scope == ApiScope.public;
}

class RouteTable {
  /// Throws if a declared endpoint has no handler, or a handler is bound to an
  /// endpoint that is not declared, so the mistake fails the first test that
  /// builds a server.
  RouteTable(Iterable<RouteSource> sources, {ApiRouteIndex? index})
    : index = index ?? apiRouteIndex {
    final bound = <ApiRoute, Function>{};
    for (final source in sources) {
      for (final entry in source.routes.entries) {
        final route = entry.key.route;
        if (bound.containsKey(route)) {
          throw StateError('${route.signature} is bound to two handlers');
        }
        bound[route] = entry.value;
      }
    }
    final handlers = <Function>[];
    for (final route in this.index.routes) {
      final handler = bound.remove(route);
      if (handler == null) {
        throw StateError('${route.signature} is declared but has no handler');
      }
      handlers.add(handler);
    }
    if (bound.isNotEmpty) {
      throw StateError(
        'Handlers are bound to routes missing from apiRouteGroups: '
        '${bound.keys.map((route) => route.signature).join(', ')}',
      );
    }
    _handlers = handlers;
  }

  /// A table of one handler class's routes alone, in the order it lists them.
  RouteTable.only(RouteSource source)
    : this([
        source,
      ], index: ApiRouteIndex(source.routes.keys.map((e) => e.route)));

  final ApiRouteIndex index;
  late final List<Function> _handlers;

  /// Resolves and dispatches with no middleware in between.
  Handler get handler => resolveMiddleware(dispatch);

  static const String _contextKey = 'skotiq.route';

  /// The routes in match order.
  List<ApiRoute> get routes => index.routes;

  /// The route context [resolveMiddleware] attached to [request].
  static RouteContext of(Request request) =>
      request.context[_contextKey]! as RouteContext;

  RouteContext resolve(String method, String path) {
    final resolution = index.resolve(method, path);
    return RouteContext(resolution, index.policyOf(resolution, method, path));
  }

  /// Finds the route once, ahead of every other middleware.
  Middleware get resolveMiddleware => (innerHandler) {
    return (request) {
      final context = resolve(request.method, '/${request.url.path}');
      return innerHandler(request.change(context: {_contextKey: context}));
    };
  };

  /// The innermost handler: runs the matched route's handler.
  Future<Response> dispatch(Request request) async {
    final resolution = of(request).resolution;
    switch (resolution) {
      case ApiRouteNotFound():
        return Router.routeNotFound;
      case ApiMethodNotAllowed():
        final response = _methodNotAllowed(request, resolution);
        return request.method == 'HEAD' ? _withoutBody(response) : response;
      case ApiRouteMatched(:final position, params: final encoded):
        final handler = _handlers[position];
        final params = _decoded(encoded);
        final routed = request.change(context: {'shelf_router/params': params});
        final Response response;
        if (handler is Handler || params.isEmpty) {
          response = await (handler as dynamic)(routed) as Response;
        } else {
          response =
              await Function.apply(handler, [routed, ...params.values])
                  as Response;
        }
        return request.method == 'HEAD' ? _withoutBody(response) : response;
    }
  }

  /// Path parameter values as the caller meant them: clients percent-encode
  /// each one as a single segment (`ApiRoute.fill`). shelf has already
  /// refused a request whose path does not decode.
  static Map<String, String> _decoded(Map<String, String> params) => {
    for (final MapEntry(key: name, :value) in params.entries)
      name: Uri.decodeComponent(value),
  };

  static Response _withoutBody(Response response) {
    final headers = response.headers.containsKey('content-length')
        ? {'content-length': '0'}
        : null;
    return response.change(headers: headers, body: <int>[]);
  }

  static Response _methodNotAllowed(
    Request request,
    ApiMethodNotAllowed refusal,
  ) {
    final allow = refusal.allow;
    return Response(
      405,
      body: jsonEncode({
        'error':
            '${request.method} is not supported for ${refusal.path}. This '
            'endpoint accepts: $allow.',
        'code': 'method_not_allowed',
        'allow': allow,
      }),
      // RFC 9110 requires Allow on a 405, and it is what lets a client fix
      // itself without reading the route table.
      headers: {'content-type': 'application/json', 'allow': allow},
    );
  }
}
