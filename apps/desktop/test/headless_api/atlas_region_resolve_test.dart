// The three /api/atlas/region/<id>/... routes share one _resolveRegion
// preamble. The existing atlas_handlers_error_test covers the
// 400 (non-integer id) branch for all three routes; this file exercises the
// 404 (region_not_found) branch of the same helper against a real, empty atlas
// service so both arms of the extracted helper are covered.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/atlas_handlers.dart';
import 'package:shelf/shelf.dart';

/// Minimal [SkyAtlasSeam] — never invoked on the region-not-found path (which
/// only touches the DAO), but required to construct the service.
class _NoopSkyAtlasSeam implements SkyAtlasSeam {
  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async =>
      const {'ok': true};

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async =>
      const {'ok': true};

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async =>
      const {'ok': true};

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async =>
      const {'ok': true};

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async =>
      const {'ok': true};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AtlasHandlers _resolveRegion 404 branch', () {
    late SkotiqDatabase db;
    late ProviderContainer container;
    late AtlasHandlers handlers;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final service = SkyAtlasService(
        dao: SkyAtlasDao(db),
        seam: _NoopSkyAtlasSeam(),
        logger: LoggingService(),
        atlasRootResolver: () async => '/tmp/test_atlas',
      );
      container = ProviderContainer(
        overrides: [skyAtlasServiceProvider.overrideWithValue(service)],
      );
      handlers = AtlasHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> expectRegionNotFound(Response response) async {
      expect(response.statusCode, HttpStatus.notFound);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'region_not_found');
      expect(body['message'], 'region 999 not found');
    }

    test('handleGetRegion returns 404 for a missing region', () async {
      await expectRegionNotFound(
        await handlers.handleGetRegion(
          Request('GET', Uri.parse('http://localhost/api/atlas/region/999')),
          '999',
        ),
      );
    });

    test('handleGetRegionTimeline returns 404 for a missing region', () async {
      await expectRegionNotFound(
        await handlers.handleGetRegionTimeline(
          Request(
            'GET',
            Uri.parse('http://localhost/api/atlas/region/999/timeline'),
          ),
          '999',
        ),
      );
    });
  });
}
