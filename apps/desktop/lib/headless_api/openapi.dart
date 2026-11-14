/// OpenAPI 3.0 spec generation for the headless route table.
library;

import 'package:skotiq_core/models.dart' show DeviceType;
import 'package:skotiq_remote_protocol/wire.dart';

import 'rate_limiting.dart';

Map<String, dynamic> openApiRequestBodyFor({required String path}) {
  final schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': true,
  };
  var required = false;

  if (path == DeviceApi.connectDevice.route.path ||
      path == DeviceApi.disconnectDevice.route.path) {
    required = true;
    schema
      ..['additionalProperties'] = false
      ..['required'] = <String>['deviceId', 'deviceType']
      ..['properties'] = <String, dynamic>{
        'deviceId': {'type': 'string', 'minLength': 1},
        'deviceType': {
          'type': 'string',
          'enum': [for (final type in DeviceType.values) type.name],
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

/// The OpenAPI document for the advertised routes, read off their
/// declarations.
Map<String, dynamic> buildOpenApiSpec({
  required Iterable<ApiRoute> routes,
  required int port,
}) {
  final paths = <String, Map<String, dynamic>>{};

  for (final route in routes) {
    if (route.method == ApiMethod.ws) continue;

    final method = route.method.wireName;
    final path = openApiPath(route.path);
    final public = route.scope == ApiScope.public;
    final responses = <String, Map<String, String>>{
      '200': {'description': 'Success'},
      '400': {'description': 'Bad request'},
      '500': {'description': 'Internal server error'},
      '426': {'description': 'Upgrade required for API version mismatch'},
    };
    final operation = <String, dynamic>{
      'summary': route.signature,
      'tags': [openApiTag(path)],
      'responses': responses,
      'x-auth-required': !public,
      'x-required-scope': route.scope.name,
    };

    if (!public) {
      responses['401'] = {'description': 'Unauthorized'};
      responses['403'] = {'description': 'Forbidden'};
      operation['security'] = [
        {'bearerAuth': <String>[]},
      ];
    }

    if (route.method.mayCarryBody) {
      responses['413'] = {'description': 'Request body too large'};
      operation['x-max-request-body-bytes'] = route.maxBodyBytes;
      operation['requestBody'] = openApiRequestBodyFor(path: route.path);
    }

    final maxRequests = route.rate.maxRequestsPerMinute;
    if (maxRequests != null) {
      responses['429'] = {'description': 'Rate limit exceeded'};
      operation['x-rate-limit'] = {
        'maxRequests': maxRequests,
        'windowSeconds': endpointRateLimitWindow.inSeconds,
      };
    }

    if (route.audit != null) {
      operation['x-audit-action'] = route.audit;
    }

    final operations = paths.putIfAbsent(path, () => <String, dynamic>{});
    operations[method.toLowerCase()] = operation;
  }

  return {
    'openapi': '3.0.3',
    'info': {
      'title': 'Skotiq Headless API',
      'version': skotiqRelease,
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
