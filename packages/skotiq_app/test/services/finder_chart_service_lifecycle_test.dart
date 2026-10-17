import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/finder_chart_service.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _quietRenderConfig = SkyRenderConfig(
  showStars: false,
  showConstellationLines: false,
  showConstellationLabels: false,
  showDSOs: false,
  showDSOLabels: false,
  showHorizon: false,
  showCardinalDirections: false,
  showMountPosition: false,
  showSun: false,
  showMoon: false,
  showPlanets: false,
  showGroundPlane: false,
);

Future<void> _generate(String outputPath, int resolution) {
  return FinderChartService.generateChart(
    outputPath: outputPath,
    viewState: const SkyViewState(centerRA: 5, centerDec: 10),
    renderConfig: _quietRenderConfig,
    stars: const [],
    dsos: const [],
    constellations: const [],
    observationTime: DateTime.utc(2026, 7, 14),
    latitude: 40,
    longitude: -75,
    chartConfig: FinderChartConfig(chartResolution: resolution),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('finder chart releases native resources after PDF export', () async {
    final directory = await Directory.systemTemp.createTemp('finder_chart_');
    addTearDown(() => directory.delete(recursive: true));
    final output = File('${directory.path}/chart.pdf');

    final createdImages = <ui.Image>[];
    final disposedImages = <ui.Image>[];
    final createdPictures = <ui.Picture>[];
    final disposedPictures = <ui.Picture>[];
    final previousImageCreate = ui.Image.onCreate;
    final previousImageDispose = ui.Image.onDispose;
    final previousPictureCreate = ui.Picture.onCreate;
    final previousPictureDispose = ui.Picture.onDispose;
    ui.Image.onCreate = (image) {
      previousImageCreate?.call(image);
      createdImages.add(image);
    };
    ui.Image.onDispose = (image) {
      previousImageDispose?.call(image);
      disposedImages.add(image);
    };
    ui.Picture.onCreate = (picture) {
      previousPictureCreate?.call(picture);
      createdPictures.add(picture);
    };
    ui.Picture.onDispose = (picture) {
      previousPictureDispose?.call(picture);
      disposedPictures.add(picture);
    };

    try {
      await _generate(output.path, 320);
    } finally {
      ui.Image.onCreate = previousImageCreate;
      ui.Image.onDispose = previousImageDispose;
      ui.Picture.onCreate = previousPictureCreate;
      ui.Picture.onDispose = previousPictureDispose;
    }

    expect((await output.readAsBytes()).take(4), [37, 80, 68, 70]);
    expect(createdImages, hasLength(1));
    expect(disposedImages, unorderedEquals(createdImages));
    expect(createdPictures, hasLength(1));
    expect(disposedPictures, unorderedEquals(createdPictures));
  });

  test('failed rasterization still closes the active picture', () async {
    final createdPictures = <ui.Picture>[];
    final disposedPictures = <ui.Picture>[];
    final previousPictureCreate = ui.Picture.onCreate;
    final previousPictureDispose = ui.Picture.onDispose;
    ui.Picture.onCreate = (picture) {
      previousPictureCreate?.call(picture);
      createdPictures.add(picture);
    };
    ui.Picture.onDispose = (picture) {
      previousPictureDispose?.call(picture);
      disposedPictures.add(picture);
    };

    Object? failure;
    try {
      try {
        await _generate('/unused/chart.pdf', 0);
      } catch (error) {
        failure = error;
      }
    } finally {
      ui.Picture.onCreate = previousPictureCreate;
      ui.Picture.onDispose = previousPictureDispose;
    }

    expect(failure, isNotNull);
    expect(createdPictures, hasLength(1));
    expect(disposedPictures, unorderedEquals(createdPictures));
  });
}
