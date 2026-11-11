/// Finds the route a request is for.
library;

import 'api_route.dart';

/// What [ApiRouteIndex.resolve] found for a method and a concrete path.
sealed class ApiRouteResolution {
  const ApiRouteResolution();
}

final class ApiRouteMatched extends ApiRouteResolution {
  const ApiRouteMatched(this.position, this.route, this.params);

  /// Index of [route] in the list the index was built from.
  final int position;
  final ApiRoute route;

  /// Path parameter values in template order, as they appear in the path
  /// (not percent-decoded).
  final Map<String, String> params;
}

/// The path is a declared literal path, but not with this method.
final class ApiMethodNotAllowed extends ApiRouteResolution {
  const ApiMethodNotAllowed(this.path, this.siblings);

  final String path;

  /// The routes that are declared on this path, in declaration order.
  final List<ApiRoute> siblings;

  /// The value for the `Allow` header.
  String get allow => [
    for (final method in _allowOrder)
      if (siblings.any((route) => route.method.httpVerb == method)) method,
  ].join(', ');

  static const _allowOrder = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];
}

final class ApiRouteNotFound extends ApiRouteResolution {
  const ApiRouteNotFound();
}

/// Lookup over an ordered route list with first-match-wins semantics: the
/// same answer as walking the list and testing every route, without the walk.
///
/// Literal paths are found by hash. Only the parameterized routes whose
/// literal prefix the path starts with are tested by pattern.
class ApiRouteIndex {
  ApiRouteIndex(Iterable<ApiRoute> routes)
    : routes = List.unmodifiable(routes) {
    for (var i = 0; i < this.routes.length; i++) {
      final route = this.routes[i];
      if (route.path.contains('<')) {
        _patterns.add(_PatternRoute(i, route));
      } else {
        _literals.putIfAbsent(route.path, () => <int>[]).add(i);
      }
    }
  }

  final List<ApiRoute> routes;
  final Map<String, List<int>> _literals = {};
  final List<_PatternRoute> _patterns = [];

  /// [method] is the HTTP verb of the request. HEAD resolves as GET.
  ApiRouteResolution resolve(String method, String path) {
    var verb = method.toUpperCase();
    if (verb == 'HEAD') verb = 'GET';

    final literal = _literals[path];
    if (literal != null) {
      for (final position in literal) {
        if (routes[position].method.httpVerb == verb) {
          return _earlierPattern(verb, path, position) ??
              ApiRouteMatched(position, routes[position], const {});
        }
      }
      // A parameterized route declared before the path's last literal route
      // still takes the request; one declared after it does not, so that
      // `GET /things/find` on a POST-only `/things/find` is refused as the
      // wrong method instead of being read as `GET /things/<id>`.
      final pattern = _earlierPattern(verb, path, literal.last);
      if (pattern != null) return pattern;
      if (_stubVerbs.contains(verb)) {
        return ApiMethodNotAllowed(path, [
          for (final position in literal) routes[position],
        ]);
      }
      return const ApiRouteNotFound();
    }

    return _earlierPattern(verb, path, routes.length) ??
        const ApiRouteNotFound();
  }

  /// The policy a request is held to: its route, or for a request that
  /// matches none (and will be answered 404 or 405), what its verb would
  /// need on the path's own resource. A path with a public route stays
  /// public, so the pairing and dashboard paths answer without a token.
  ApiRoute policyFor(String method, String path) =>
      policyOf(resolve(method, path), method, path);

  ApiRoute policyOf(ApiRouteResolution resolution, String method, String path) {
    final List<ApiRoute> siblings;
    switch (resolution) {
      case ApiRouteMatched(:final route):
        return route;
      case ApiMethodNotAllowed():
        siblings = resolution.siblings;
      case ApiRouteNotFound():
        siblings = const [];
    }
    final verb = method.toUpperCase();
    final read = verb == 'GET' || verb == 'HEAD';
    final public = siblings.any((route) => route.scope == ApiScope.public);
    return ApiRoute(
      read ? ApiMethod.get : ApiMethod.post,
      path,
      resource: siblings.isEmpty ? ApiResource.system : siblings.first.resource,
      scope: public
          ? ApiScope.public
          : (read ? ApiScope.view : ApiScope.control),
      timeout: read ? ApiTimeout.read : ApiTimeout.command,
      bucket: read ? ApiBucket.read : ApiBucket.write,
    );
  }

  /// The first parameterized route before [limit] that takes the request.
  ApiRouteMatched? _earlierPattern(String verb, String path, int limit) {
    for (final candidate in _patterns) {
      if (candidate.position >= limit) break;
      if (candidate.route.method.httpVerb != verb) continue;
      if (!path.startsWith(candidate.prefix)) continue;
      final match = candidate.pattern.firstMatch(path);
      if (match == null) continue;
      return ApiRouteMatched(candidate.position, candidate.route, {
        for (var i = 0; i < candidate.params.length; i++)
          candidate.params[i]: match[i + 1]!,
      });
    }
    return null;
  }

  static const _stubVerbs = {'GET', 'POST', 'PUT', 'DELETE', 'PATCH'};
}

class _PatternRoute {
  _PatternRoute(this.position, this.route)
    : prefix = route.path.substring(0, route.path.indexOf('<')) {
    final buffer = StringBuffer('^');
    for (final part in _templateParts.allMatches(route.path)) {
      buffer.write(RegExp.escape(part[1]!));
      if (part[2] != null) {
        params.add(part[2]!);
        buffer.write('(${part[3] ?? r'[^/]+'})');
      }
    }
    buffer.write(r'$');
    pattern = RegExp(buffer.toString());
  }

  final int position;
  final ApiRoute route;
  final String prefix;
  final List<String> params = [];
  late final RegExp pattern;

  static final RegExp _templateParts = RegExp(
    r'([^<]*)(?:<([^>|]+)(?:\|([^>]*))?>)?',
  );
}
