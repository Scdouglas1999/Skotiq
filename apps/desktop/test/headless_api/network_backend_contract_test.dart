import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';

void main() {
  group('headless API route contracts', () {
    // A-5b's route-table refactor relocated route
    // registrations from inline `router.<verb>(...)` calls in
    // `headless_api_server.dart` into per-domain `routes/*.dart` files,
    // and moved the advertised-endpoint catalog from
    // `_getAvailableEndpoints()` in the server class to
    // `availableHeadlessEndpoints()` in `handlers/system_handlers.dart`.
    // These scanners follow the new locations.

    test('advertised endpoints match registered API routes', () {
      final registered = _registeredApiRoutes();
      final advertised = _advertisedApiRoutes();

      expect(
        advertised.difference(registered),
        isEmpty,
        reason: 'Advertised endpoints must be registered by HeadlessApiServer.',
      );
      expect(
        registered.difference(advertised),
        isEmpty,
        reason:
            'Every registered API endpoint must be advertised in /api/info and OpenAPI.',
      );
    });

    test('NetworkBackend call sites map to registered server routes', () {
      final clientSource = _networkBackendSource();

      final registered = _registeredApiRoutes()
          .where((route) => !route.startsWith('WS '))
          .toSet();
      final clientRoutes = _networkBackendRoutes(clientSource);

      expect(
        clientRoutes.difference(registered),
        isEmpty,
        reason: 'NetworkBackend must not call endpoints missing on the server.',
      );
    });

    test('OpenAPI spec advertises every HTTP route from the route table', () {
      final advertised = _advertisedApiRoutes();
      final spec = buildOpenApiSpec(routes: advertised.toList(), port: 8080);
      final paths = spec['paths'] as Map<String, dynamic>;

      for (final route in advertised.where(
        (route) => !route.startsWith('WS '),
      )) {
        final parts = route.split(' ');
        final method = parts.first.toLowerCase();
        final path = openApiPath(parts.last);
        expect(
          paths[path],
          contains(method),
          reason: 'OpenAPI must include advertised route $route.',
        );
      }

      expect(
        paths.keys.any((path) => path == '/api/ws' || path == '/events'),
        isFalse,
        reason:
            'WebSocket endpoints are advertised in /api/info but not OpenAPI.',
      );
    });
  });

  // Wave 3 / Living Sky master-slave parity net.
  //
  // The slave-blind bug class (a companion tablet reading empty local state
  // because a Living Sky NetworkBackend method had no registered/advertised
  // host route) shipped because nothing pinned the wire seam per-pillar. The
  // generic scanners above catch a missing route for ANY backend call; this
  // group makes the Living Sky coverage EXPLICIT so a regression names the
  // exact pillar surface that lost its host route, and documents Constellation's
  // host-only status so adding a slave method without a route fails loudly.
  group('Living Sky master/slave route parity', () {
    // Every NetworkBackend Living-Sky read/triage call a slave issues, and the
    // host route it must map to. Mirrors the @ session_science_operations.dart
    // mixin (Pillar A "Your Sky" + Pillar B "First Light"). Kept as an explicit
    // expectation so a dropped/renamed route is a named parity failure, not a
    // generic diff.
    const livingSkyClientRoutes = <String>{
      // Pillar A — Your Sky (atlas)
      'GET /api/atlas/regions',
      'POST /api/atlas/regions',
      'GET /api/atlas/coverage',
      'GET /api/atlas/region/{param}',
      'GET /api/atlas/region/{param}/timeline',
      'GET /api/atlas/region/{param}/cutout',
      // Pillar B — First Light (transient discovery)
      'GET /api/firstlight/candidates',
      'GET /api/firstlight/near',
      'GET /api/firstlight/{param}/crops/{param}',
      'POST /api/firstlight/{param}/review',
      'POST /api/firstlight/{param}/dismiss',
      'POST /api/firstlight/{param}/submit/tns',
      'POST /api/firstlight/{param}/export/aavso',
      'POST /api/firstlight/{param}/export/mpc',
    };

    test('every Living Sky NetworkBackend call is registered + advertised', () {
      final clientSource = _networkBackendSource();
      final clientRoutes = _networkBackendRoutes(clientSource);
      final registered = _registeredApiRoutes();
      final advertised = _advertisedApiRoutes();

      for (final route in livingSkyClientRoutes) {
        expect(
          clientRoutes,
          contains(route),
          reason:
              'NetworkBackend must keep a client method for $route so a slave '
              'surfaces host Living Sky data instead of empty local state.',
        );
        expect(
          registered,
          contains(route),
          reason: 'Living Sky route $route must be registered on the host.',
        );
        expect(
          advertised,
          contains(route),
          reason:
              'Living Sky route $route must be advertised in /api/info so the '
              'slave can discover it.',
        );
      }
    });

    // Pillar C (Constellation) talks to a SEPARATE community hub via
    // ConstellationClient, not the headless_api slave seam — so a slave/tablet
    // has NO NetworkBackend Constellation method today (the documented
    // "Constellation interactive on a slave but silently can't work" gap). Pin
    // that host-only status: if someone later adds a NetworkBackend
    // constellation/swarm/shared-target method, this guard forces them to also
    // register + advertise its host route (closing the slave-blind class for C
    // the way it is closed for A and B).
    test('Constellation NetworkBackend calls (if any) map to host routes', () {
      final clientSource = _networkBackendSource();
      final clientRoutes = _networkBackendRoutes(clientSource);
      final registered = _registeredApiRoutes()
          .where((route) => !route.startsWith('WS '))
          .toSet();
      final advertised = _advertisedApiRoutes();

      final constellationCalls = clientRoutes
          .where(
            (route) =>
                route.contains('/constellation') ||
                route.contains('/swarm') ||
                route.contains('/shared-target') ||
                route.contains('/sharedtarget'),
          )
          .toSet();

      for (final route in constellationCalls) {
        expect(
          registered,
          contains(route),
          reason:
              'A new Constellation slave method ($route) must register a host '
              'route — a slave Constellation call with no route is the '
              'slave-blind bug class.',
        );
        expect(
          advertised,
          contains(route),
          reason: 'Constellation route $route must be advertised in /api/info.',
        );
      }
    });
  });
}

/// Scan all per-domain route files under `lib/headless_api/routes/` for
/// `HeadlessRoute(HttpMethod.<verb>, '<path>', ...)` entries, plus the
/// remaining inline `router.<verb>(...)` calls in `headless_api_server.dart`
/// (WebSocket upgrade routes still live there because they take a built
/// `Handler` closure).
Set<String> _registeredApiRoutes() {
  final routeFiles = Directory('lib/headless_api/routes')
      .listSync()
      .whereType<File>()
      .where(
        (f) =>
            f.path.endsWith('.dart') && !f.path.endsWith('headless_route.dart'),
      );
  final allSource = StringBuffer();
  for (final f in routeFiles) {
    allSource.writeln(f.readAsStringSync());
  }
  allSource.writeln(File('lib/headless_api_server.dart').readAsStringSync());
  return _scanRegisteredRoutes(allSource.toString());
}

Set<String> _scanRegisteredRoutes(String source) {
  final headlessRoutes =
      RegExp(
        r"HeadlessRoute\(\s*HttpMethod\.(get|post|put|delete)\s*,\s*'([^']+)'",
      ).allMatches(source).map((match) {
        final path = match.group(2)!;
        // Same WS-route classification rule as the legacy inline-route scanner:
        // `/api/ws`, `/events`, and `/ws/*` upgrade routes are advertised as
        // `WS <path>` in `availableHeadlessEndpoints()`, even though shelf_router
        // registers them as HTTP GET handlers. websocket_routes.dart does this.
        final isWsRoute =
            path == '/api/ws' || path == '/events' || path.startsWith('/ws/');
        // Static-file routes (`/dashboard`, `/broadcast`, `/run-watch`) are
        // registered but deliberately NOT advertised in the API catalog —
        // they're operator-facing pages, not endpoints clients call.
        if (!path.startsWith('/api/') && !isWsRoute) {
          return null;
        }
        final method = isWsRoute ? 'WS' : match.group(1)!.toUpperCase();
        return '$method ${_normalizeRoute(path)}';
      }).whereType<String>();
  final inlineRoutes = RegExp(r"router\.(get|post|put|delete)\(\s*'([^']+)'")
      .allMatches(source)
      .map((match) {
        final path = match.group(2)!;
        // also surface `/ws/*` upgrade routes (e.g. /ws/live-view)
        // so the advertised-vs-registered diff catches typos in either
        // place.
        final isWsRoute =
            path == '/api/ws' || path == '/events' || path.startsWith('/ws/');
        if (!path.startsWith('/api/') && !isWsRoute) {
          return null;
        }

        final method = isWsRoute ? 'WS' : match.group(1)!.toUpperCase();
        return '$method ${_normalizeRoute(path)}';
      })
      .whereType<String>();
  return {...headlessRoutes, ...inlineRoutes};
}

Set<String> _advertisedApiRoutes() {
  // A-5b moved this catalog from `_getAvailableEndpoints()` in
  // `headless_api_server.dart` to `availableHeadlessEndpoints()`; it now lives
  // in its own `handlers/system_endpoint_catalog.dart` (re-exported from
  // `handlers/system_handlers.dart`).
  final source = File(
    'lib/headless_api/handlers/system_endpoint_catalog.dart',
  ).readAsStringSync();
  final match = RegExp(
    r'List<String> availableHeadlessEndpoints\(\) \{\s*return (?:const )?\[(.*?)\];\s*\}',
    dotAll: true,
  ).firstMatch(source);

  expect(
    match,
    isNotNull,
    reason:
        'availableHeadlessEndpoints() not found in system_endpoint_catalog.dart.',
  );

  return RegExp(r"'([^']+)'").allMatches(match!.group(1)!).map((match) {
    final parts = match.group(1)!.split(' ');
    expect(parts, hasLength(2));
    return '${parts[0]} ${_normalizeRoute(parts[1])}';
  }).toSet();
}

Set<String> _networkBackendRoutes(String source) {
  return RegExp(
    r"_(get|post|put|delete|downloadBytes|postRaw|postRawBytes)\(\s*'([^']+)'",
  ).allMatches(source).map((match) {
    final method = switch (match.group(1)!) {
      'get' => 'GET',
      'post' => 'POST',
      'put' => 'PUT',
      'delete' => 'DELETE',
      'downloadBytes' => 'GET',
      'postRaw' => 'POST',
      'postRawBytes' => 'POST',
      _ => throw StateError('Unsupported NetworkBackend helper'),
    };
    return '$method /api/${_normalizeRoute(match.group(2)!)}';
  }).toSet();
}

String _networkBackendSource() {
  const backendRoot = '../../packages/skotiq_core/lib/src/backend';
  final sources = <String>[
    File('$backendRoot/network_backend.dart').readAsStringSync(),
  ];
  final partsDirectory = Directory('$backendRoot/network_backend');
  if (!partsDirectory.existsSync()) {
    return sources.single;
  }
  final partFiles =
      partsDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  sources.addAll(partFiles.map((file) => file.readAsStringSync()));
  return sources.join('\n');
}

String _normalizeRoute(String path) {
  final querylessPath = path.split('?').first;
  return querylessPath
      .replaceAllMapped(RegExp(r'<([^>|]+)(?:\|[^>]+)?>'), (_) => '{param}')
      .replaceAllMapped(RegExp(r'\$\{[^}]+\}'), (_) => '{param}')
      .replaceAllMapped(RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*'), (_) => '{param}')
      .replaceAllMapped(RegExp(r'\{[^}]+\}'), (_) => '{param}');
}
