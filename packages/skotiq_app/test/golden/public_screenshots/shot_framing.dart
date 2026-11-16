// Framing on NGC 7331 over the SDSS color survey: the cutout the screen asks
// for (2.0 x 1.5 degrees, 800 x 600) is served from `test/fixtures/framing/`
// (source and credit in `test/fixtures/README.md`).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../surface_golden_harness.dart';
import 'shot_night.dart';

/// The survey request the screen made that the fixture does not answer.
final missingCutouts = <Uri>{};

File _cutout() => File(
      '${SurfaceGoldenHarness.repoRoot().path}'
      '/packages/skotiq_app/test/fixtures/framing/ngc7331_sdss_color.jpg',
    );

List<Override> framingOverrides() => [
      framingProvider.overrideWith(
        (ref) => FramingNotifier(ref)
          ..setSurveySource(SurveySource.sdss)
          ..setTargetCoordinates(
            ShotNight.ngc7331.raHours,
            ShotNight.ngc7331.decDegrees,
            name: ShotNight.ngc7331.name,
          ),
      ),
      framingSurveyHttpClientFactoryProvider.overrideWithValue(
        () => MockClient((request) async {
          final file = _cutout();
          if (request.url.host.startsWith('alasky') && file.existsSync()) {
            return http.Response.bytes(
              await file.readAsBytes(),
              200,
              headers: {'content-type': 'image/jpeg'},
            );
          }
          missingCutouts.add(request.url);
          return http.Response('', 404);
        }),
      ),
    ];
