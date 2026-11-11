/// OpenAPI 3.0 spec generation for the headless route table.
library;

import 'body_limits.dart';
import 'path_classification.dart';

Map<String, dynamic> openApiRequestBodyFor({required String path}) {
  final schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': true,
  };
  var required = false;

  if (path == '/api/devices/connect' || path == '/api/devices/disconnect') {
    required = true;
    schema
      ..['additionalProperties'] = false
      ..['required'] = <String>['deviceId', 'deviceType']
      ..['properties'] = <String, dynamic>{
        'deviceId': {'type': 'string', 'minLength': 1},
        'deviceType': {
          'type': 'string',
          'enum': const <String>[
            'camera',
            'mount',
            'focuser',
            'filterWheel',
            'guider',
            'rotator',
            'dome',
            'weather',
            'safetyMonitor',
            'switch_',
            'coverCalibrator',
          ],
        },
      };
  }

  return {
    'required': required,
    'content': {
      'application/json': {'schema': schema},
    },
  };
}

Map<String, dynamic> buildOpenApiSpec({
  required List<String> routes,
  required int port,
}) {
  final paths = <String, Map<String, dynamic>>{};

  for (final route in routes) {
    final parts = route.split(' ');
    if (parts.length != 2) continue;

    final method = parts.first.toUpperCase();
    if (method == 'WS') continue;

    final routePath = parts.last;
    final path = openApiPath(routePath);
    final rateLimit = endpointRateLimitFor(method: method, path: routePath);
    final auditAction = highRiskAuditActionFor(method: method, path: routePath);
    final authScope = requiredAuthScopeNameForEndpoint(
      method: method,
      path: routePath,
    );
    final publicEndpoint = isPublicEndpoint(method: method, path: routePath);
    final responses = <String, Map<String, String>>{
      '200': {'description': 'Success'},
      '400': {'description': 'Bad request'},
      '500': {'description': 'Internal server error'},
      '426': {'description': 'Upgrade required for API version mismatch'},
    };
    final operation = <String, dynamic>{
      'summary': route,
      'tags': [openApiTag(path)],
      'responses': responses,
      'x-auth-required': !publicEndpoint,
      'x-required-scope': authScope,
    };

    if (!publicEndpoint) {
      responses['401'] = {'description': 'Unauthorized'};
      responses['403'] = {'description': 'Forbidden'};
      operation['security'] = [
        {'bearerAuth': <String>[]},
      ];
    }

    if (methodCanHaveBody(method)) {
      responses['413'] = {'description': 'Request body too large'};
      operation['x-max-request-body-bytes'] = requestBodyLimitForPath(
        routePath,
      );
      operation['requestBody'] = openApiRequestBodyFor(path: routePath);
    }

    if (rateLimit != null) {
      responses['429'] = {'description': 'Rate limit exceeded'};
      operation['x-rate-limit'] = {
        'maxRequests': rateLimit.maxRequests,
        'windowSeconds': rateLimit.window.inSeconds,
      };
    }

    if (auditAction != null) {
      operation['x-audit-action'] = auditAction;
    }

    final operations = paths.putIfAbsent(path, () => <String, dynamic>{});
    operations[method.toLowerCase()] = operation;
  }

  return {
    'openapi': '3.0.3',
    'info': {
      'title': 'Skotiq Headless API',
      // minor bump for the additive event sequencing
      // (`seq`, `serverInstanceId`, `replay`, `resync_required`) and
      // command/event correlation (`commandId`, `correlatingCommandId`).
      // Existing clients ignore the new fields; no breaking change.
      'version': '2.6.0',
      'description':
          'Event envelope now carries `seq`, `serverInstanceId`, and '
          '`correlatingCommandId`. Action POSTs return a `commandId`. '
          'GET /api/info exposes `currentEventSeq`, '
          '`eventReplayBufferOldestSeq`, and `eventReplayBufferSize` '
          'so clients can decide between WS `?since=` replay and a '
          'full snapshot rehydrate.',
    },
    'servers': [
      {'url': 'http://localhost:$port'},
    ],
    'components': {
      'securitySchemes': {
        'bearerAuth': {
          'type': 'http',
          'scheme': 'bearer',
          'bearerFormat': 'Skotiq headless token',
        },
      },
    },
    'paths': paths,
  };
}

String openApiPath(String routePath) {
  return routePath.replaceAllMapped(
    RegExp(r'<([^>|]+)(?:\|[^>]+)?>'),
    (match) => '{${match.group(1)}}',
  );
}

String openApiTag(String routePath) {
  final segments = routePath.split('/').where((segment) {
    return segment.isNotEmpty && segment != 'api';
  }).toList();
  if (segments.isEmpty) return 'core';
  return segments.first.replaceAll('-', ' ');
}
