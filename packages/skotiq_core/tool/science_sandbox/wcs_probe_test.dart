// Probe: does the stored WCS, projected the way the science pipeline projects
// catalog stars (GnomonicProjection), land APASS stars on the stars Skotiq
// detects? Prints match counts for the production mapping and for the axis
// flips, so a convention mismatch shows up as one variant matching and the
// production one not.
//
//   SKOTIQ_DATABASE_DIR=<sandbox db dir> SKOTIQ_DATA_DIR=<db>/data \
//   PROBE_IMAGE_ID=<captured_images.id> flutter test tool/science_sandbox/wcs_probe_test.dart
//
// Run it on a sandbox database that no other run has open.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/models/science/science_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/science/default_science_backend.dart';
import 'package:skotiq_core/src/services/science/photometric_catalog_service.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_core/src/services/wcs/wcs_sip_codec.dart';

void main() {
  final imageId = int.tryParse(Platform.environment['PROBE_IMAGE_ID'] ?? '');
  test(
    'wcs probe',
    () async {
      await bridge.NativeBridge.init();
      final container = ProviderContainer();
      await container.read(backendProvider.notifier).useLocalBackend();
      final database = container.read(databaseProvider);
      final row = await database
          .customSelect(
            'SELECT * FROM captured_images WHERE id = ?',
            variables: [drift.Variable<int>(imageId!)],
          )
          .getSingle();
      final path = row.read<String>('file_path');
      final fits = await bridge.apiReadFitsFile(filePath: path);
      final sip = decodeSolvedSip(row.readNullable<String>('solved_sip'));
      final wcs = SolvedWcs(
        raHours: row.read<double>('solved_ra'),
        decDegrees: row.read<double>('solved_dec'),
        rotationDeg: row.read<double>('solved_rotation'),
        pixelScaleArcsec: row.read<double>('solved_pixel_scale'),
        imageWidth: fits.width,
        imageHeight: fits.height,
        cd1_1: row.readNullable<double>('solved_cd1_1'),
        cd1_2: row.readNullable<double>('solved_cd1_2'),
        cd2_1: row.readNullable<double>('solved_cd2_1'),
        cd2_2: row.readNullable<double>('solved_cd2_2'),
        aOrder: sip?.aOrder ?? 0,
        bOrder: sip?.bOrder ?? 0,
        aCoeffs: sip?.aCoeffs ?? const [],
        bCoeffs: sip?.bCoeffs ?? const [],
      );
      final noCd = SolvedWcs(
        raHours: wcs.raHours,
        decDegrees: wcs.decDegrees,
        rotationDeg: wcs.rotationDeg,
        pixelScaleArcsec: wcs.pixelScaleArcsec,
        imageWidth: wcs.imageWidth,
        imageHeight: wcs.imageHeight,
      );
      final stars = await container
          .read(scienceBackendProvider)
          .measureStars(path, const PhotometryOptions(minSnr: 5.0));
      final cone = await container
          .read(photometricCatalogServiceProvider)
          .coneSearch(
            raDegrees: wcs.raHours * 15,
            decDegrees: wcs.decDegrees,
            radiusDegrees: 0.9,
            maxMagnitude: 15,
          );
      // ignore: avoid_print
      print(
        'image $imageId ${fits.width}x${fits.height} stars=${stars.length} '
        'catalog=${cone.stars.length} (${cone.source.name}) '
        'cd=[${wcs.cd1_1}, ${wcs.cd1_2}, ${wcs.cd2_1}, ${wcs.cd2_2}] '
        'rot=${wcs.rotationDeg} scale=${wcs.pixelScaleArcsec}',
      );
      for (final (label, w) in [('cd', wcs), ('scale+rotation', noCd)]) {
        final proj = GnomonicProjection(w);
        final pts = <(double, double)>[];
        for (final s in cone.stars) {
          final p = proj.worldToPixel(
            raDegrees: s.raDegrees,
            decDegrees: s.decDegrees,
          );
          if (p != null && p.onImage) pts.add((p.pixel.x, p.pixel.y));
        }
        final W = fits.width.toDouble(), H = fits.height.toDouble();
        final variants = <String, (double, double) Function((double, double))>{
          'production': (p) => p,
          'flipY': (p) => (p.$1, H - p.$2),
          'flipX': (p) => (W - p.$1, p.$2),
          'flipXY': (p) => (W - p.$1, H - p.$2),
        };
        for (final v in variants.entries) {
          var n = 0;
          final dx = <double>[], dy = <double>[];
          for (final p in pts.map(v.value)) {
            double best = 1e9;
            double bx = 0, by = 0;
            for (final s in stars) {
              final d = math.sqrt(
                math.pow(s.x - p.$1, 2) + math.pow(s.y - p.$2, 2),
              );
              if (d < best) {
                best = d;
                bx = s.x - p.$1;
                by = s.y - p.$2;
              }
            }
            if (best <= 9) {
              n++;
              dx.add(bx);
              dy.add(by);
            }
          }
          dx.sort();
          dy.sort();
          // ignore: avoid_print
          print(
            '$label/${v.key}: ${pts.length} on image, $n within 9 px'
            '${n > 0 ? ', median d=(${dx[n ~/ 2].toStringAsFixed(2)}, ${dy[n ~/ 2].toStringAsFixed(2)})' : ''}',
          );
        }
      }
      container.dispose();
    },
    skip: imageId == null ? 'set PROBE_IMAGE_ID' : false,
    timeout: Timeout.none,
  );
}
