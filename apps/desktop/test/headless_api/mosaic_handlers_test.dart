import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/mosaic_handlers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('MosaicHandlers', () {
    late ProviderContainer container;
    late MosaicHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = MosaicHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Map<String, Object?> config() => {
      'centerRa': 12.0,
      'centerDec': 30.0,
      'panelWidthArcmin': 60.0,
      'panelHeightArcmin': 40.0,
      'overlapPercent': 10.0,
      'panelsHorizontal': 2,
      'panelsVertical': 2,
    };

    test('generate panels returns JSON helper response', () async {
      final response = await translateHandlerErrors(
        handlers.handleGeneratePanels(
          Request(
            'POST',
            Uri.parse('http://localhost/api/mosaic/generate-panels'),
            body: jsonEncode({'config': config()}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      final panels = body['panels'] as List;
      expect(panels, hasLength(4));
      expect((panels.first as Map)['panelIndex'], 0);
    });

    test('calculate area returns total panel metadata as JSON', () async {
      final response = await translateHandlerErrors(
        handlers.handleCalculateArea(
          Request(
            'POST',
            Uri.parse('http://localhost/api/mosaic/calculate-area'),
            body: jsonEncode({'config': config()}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['areaSquareDegrees'], isA<num>());
      expect(body['totalPanels'], 4);
      // Overlap must be reflected in the coverage the wire reports. A 2x2 of
      // 60'x40' panels at 10% overlap spans (1 + 0.9) x (0.6667 + 0.6) deg
      // = 1.9 x 1.2667 = 2.4067 sq deg. Summing the panel areas as if
      // edge-to-edge gives 2.6667 and tells a remote planner the mosaic covers
      // ~11% more sky than it ever will.
      expect(
        (body['areaSquareDegrees'] as num).toDouble(),
        closeTo(1.9 * (40.0 / 60.0) * (1 + 0.9), 1e-9),
      );
    });

    test('invalid payload returns JSON internal server error', () async {
      final response = await translateHandlerErrors(
        handlers.handleValidateMosaic(
          Request(
            'POST',
            Uri.parse('http://localhost/api/mosaic/validate'),
            body: jsonEncode({'config': {}}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test('recommended exposure uses shared Smart Night context', () async {
      final scoped = ProviderContainer(
        overrides: [
          smartNightExposureContextProvider.overrideWith(
            (ref) async => const SmartNightExposureContext(
              camera: CameraExposureSpec(
                readNoiseE: 1.4,
                fullWellE: 50000,
                qePeak: 0.85,
              ),
              bortleClass: 8,
              focalLengthMm: 384,
              apertureMm: 80,
              pixelSizeMicrons: 3.76,
              availableFilterNames: ['L'],
              userCapSeconds: 240,
              floorSeconds: 30,
            ),
          ),
        ],
      );
      addTearDown(scoped.dispose);

      final scopedHandlers = MosaicHandlers(scoped);
      final response = await translateHandlerErrors(
        scopedHandlers.handleRecommendExposure(
          Request(
            'GET',
            Uri.parse('http://localhost/api/mosaic/recommended-exposure'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['exposureSeconds'], 30);
      expect(body['exposuresPerPanel'], 10);
      expect(body['filterName'], 'L');
      expect(body['source'], 'smart_night');
    });
  });
}
