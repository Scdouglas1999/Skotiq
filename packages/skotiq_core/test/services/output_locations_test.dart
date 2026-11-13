import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/services.dart';

void main() {
  late Directory temp;
  late Directory documents;
  late Directory capture;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('skotiq-output-');
    documents = await Directory(p.join(temp.path, 'Documents')).create();
    capture = await Directory(p.join(temp.path, 'Captures')).create();
  });

  tearDown(() => temp.delete(recursive: true));

  test('a night\'s masters and Darkroom files go under the capture folder', () {
    final locations = OutputLocations(
      captureFolder: '${capture.path} ',
      documents: documents,
    );

    expect(locations.root, capture.path);
    expect(locations.masters.path, p.join(capture.path, 'Masters'));
    expect(locations.darkroom.path, p.join(capture.path, 'darkroom'));
  });

  test('without a capture folder they go to Skotiq in the documents folder', () {
    final locations = OutputLocations(captureFolder: '', documents: documents);

    expect(locations.root, p.join(documents.path, 'Skotiq'));
    expect(
      locations.masters.path,
      p.join(documents.path, 'Skotiq', 'Masters'),
    );
  });

  test('each target has one masters folder, named safely', () async {
    final locations = OutputLocations(
      captureFolder: capture.path,
      documents: documents,
    );

    expect(
      (await locations.mastersOf('NGC 891 / Ha')).path,
      p.join(capture.path, 'Masters', 'NGC_891___Ha'),
    );
  });

  test(
    'a target whose masters already live in Documents/Skotiq/Masters keeps '
    'that folder',
    () async {
      final earlier = await Directory(
        p.join(documents.path, 'Skotiq', 'Masters', 'M31'),
      ).create(recursive: true);
      final locations = OutputLocations(
        captureFolder: capture.path,
        documents: documents,
      );

      expect((await locations.mastersOf('M31')).path, earlier.path);
      expect(
        (await locations.mastersOf('M33')).path,
        p.join(capture.path, 'Masters', 'M33'),
      );
    },
  );

  test(
    'once the target has a folder under the capture folder that one wins',
    () async {
      await Directory(
        p.join(documents.path, 'Skotiq', 'Masters', 'M31'),
      ).create(recursive: true);
      final current = await Directory(
        p.join(capture.path, 'Masters', 'M31'),
      ).create(recursive: true);
      final locations = OutputLocations(
        captureFolder: capture.path,
        documents: documents,
      );

      expect((await locations.mastersOf('M31')).path, current.path);
    },
  );
}
