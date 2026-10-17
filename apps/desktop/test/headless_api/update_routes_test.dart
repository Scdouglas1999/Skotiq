import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/routes/headless_route.dart';
import 'package:skotiq_desktop/headless_api/routes/update_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

void main() {
  test('unwired OTA routes remain present with a structured 503', () async {
    final router = Router();
    registerRoutes(router, buildUpdateRoutes(() => null));

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
