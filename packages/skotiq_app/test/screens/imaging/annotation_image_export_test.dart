import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/annotation_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('suggested PNG name handles remote and unsaved frames', () {
    expect(
      annotationPngSuggestedName(
        sourcePath: r'C:\captures\M31\light_001.fits.fz',
        capturedAt: DateTime(2026),
      ),
      'light_001_annotated.png',
    );
    expect(
      annotationPngSuggestedName(
        sourcePath: '/data/M42/light_002.xisf',
        capturedAt: DateTime(2026),
      ),
      'light_002_annotated.png',
    );
    expect(
      annotationPngSuggestedName(
        sourcePath: null,
        capturedAt: DateTime(2026, 7, 14, 21, 45, 6),
      ),
      'capture_20260714_214506_annotated.png',
    );
  });

  testWidgets('render failure releases every native image and picture', (
    tester,
  ) async {
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

    Object? failure;
    try {
      await tester.runAsync(() async {
        try {
          await renderAnnotatedImagePng(
            rgbaBytes: Uint8List.fromList(const [
              20,
              30,
              40,
              255,
              50,
              60,
              70,
              255,
              80,
              90,
              100,
              255,
              110,
              120,
              130,
              255,
            ]),
            width: 2,
            height: 2,
            annotation: ImageAnnotation(
              imagePath: 'remote.fit',
              timestamp: DateTime(2026),
              plateSolve: const PlateSolveData(
                ra: 0,
                dec: 0,
                pixelScale: 1,
                rotation: 0,
                fieldWidth: 1,
                fieldHeight: 1,
                imageWidth: 2,
                imageHeight: 2,
              ),
              objects: const [],
            ),
            settings: const AnnotationSettings(
              compassEnabled: false,
              scaleBarEnabled: false,
            ),
            markerStyle: const AnnotationMarkerStyle(),
            outputPath: '/chosen/export.png',
            writeBytes: (path, bytes) async {
              expect(path, '/chosen/export.png');
              expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
              throw StateError('disk full');
            },
          );
        } catch (error) {
          failure = error;
        }
      });
    } finally {
      ui.Image.onCreate = previousImageCreate;
      ui.Image.onDispose = previousImageDispose;
      ui.Picture.onCreate = previousPictureCreate;
      ui.Picture.onDispose = previousPictureDispose;
    }

    expect(
      failure,
      isA<StateError>().having(
        (error) => error.message,
        'message',
        'disk full',
      ),
    );
    expect(createdImages, hasLength(2));
    expect(disposedImages, unorderedEquals(createdImages));
    expect(createdPictures, hasLength(1));
    expect(disposedPictures, unorderedEquals(createdPictures));
  });
}
