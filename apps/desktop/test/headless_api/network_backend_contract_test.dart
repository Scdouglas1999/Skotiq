import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/openapi.dart';
import 'package:skotiq_remote_protocol/wire.dart';

void main() {
  group('headless API route contracts', () {
    // The client still writes its paths as string literals, so this reads its
    // source. Once it calls through the shared route declarations the check
    // is the compiler's.
    test('NetworkBackend call sites map to declared server routes', () {
      final clientRoutes = _networkBackendRoutes(_networkBackendSource());

      expect(
        clientRoutes.difference(_declaredHttpRoutes()),
        isEmpty,
        reason: 'NetworkBackend must not call endpoints missing on the server.',
      );
    });

    test('OpenAPI spec lists every advertised HTTP route', () {
      final routes = [
        for (final endpoint in apiEndpoints)
          if (endpoint.route.path.startsWith('/api/')) endpoint.route,
      ];
      final spec = buildOpenApiSpec(routes: routes, port: 8080);
      final paths = spec['paths'] as Map<String, dynamic>;

      for (final route in routes.where((r) => r.method != ApiMethod.ws)) {
        expect(
          paths[openApiPath(route.path)],
          contains(route.method.wireName.toLowerCase()),
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

    test('every Living Sky NetworkBackend call has a host route', () {
      final clientSource = _networkBackendSource();
      final clientRoutes = _networkBackendRoutes(clientSource);
      final declared = _declaredHttpRoutes();

      for (final route in livingSkyClientRoutes) {
        expect(
          clientRoutes,
          contains(route),
          reason:
              'NetworkBackend must keep a client method for $route so a slave '
              'surfaces host Living Sky data instead of empty local state.',
        );
        expect(
          declared,
          contains(route),
          reason: 'Living Sky route $route must be served by the host.',
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
      final declared = _declaredHttpRoutes();

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
          declared,
          contains(route),
          reason:
              'A new Constellation slave method ($route) needs a host route — '
              'a slave Constellation call with no route is the slave-blind '
              'bug class.',
        );
      }
    });
  });
}

/// The declared HTTP routes with every path parameter written `{param}`, the
/// form [_networkBackendRoutes] reduces the client's interpolations to.
Set<String> _declaredHttpRoutes() => {
  for (final endpoint in apiEndpoints)
    if (endpoint.route.method != ApiMethod.ws &&
        endpoint.route.path.startsWith('/api/'))
      '${endpoint.route.method.wireName} '
          '${_normalizeRoute(endpoint.route.path)}',
};

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
