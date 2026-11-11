// Prints the remote API route table as JSON, one object per route in match
// order: dart run tool/print_api_routes.dart
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_remote_protocol/wire.dart';

void main() {
  final rows = [
    for (final endpoint in apiEndpoints)
      {
        'method': endpoint.route.method.wireName,
        'path': endpoint.route.path,
        'scope': endpoint.route.scope.name,
        'resource': endpoint.route.resource.wireName,
        'rate': endpoint.route.rate.maxRequestsPerMinute,
        'audit': endpoint.route.audit,
        'bodyLimit': endpoint.route.maxBodyBytes,
        'timeout': endpoint.route.timeout.name,
        'bucket': endpoint.route.bucket.wireName,
        'sessionOwner': endpoint.route.sessionOwner,
        'queryToken': endpoint.route.queryToken,
      },
  ];
  stdout.writeln(const JsonEncoder.withIndent(' ').convert(rows));
}
