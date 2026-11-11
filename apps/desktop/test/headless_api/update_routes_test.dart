import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/update_handlers.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:shelf/shelf.dart';

void main() {
  test('unwired OTA routes remain present with a structured 503', () async {
    final router = RouteTable.only(UpdateRoutes(() => null)).handler;

    for (final path in [
      '/api/system/update/status',
      '/api/system/update/staged',
    ]) {
      final response = await router(
        Request('GET', Uri.parse('http://localhost$path')),
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'update_unavailable');
    }
  });
}
