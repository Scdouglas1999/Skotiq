import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('RemoteDirectoryListing.fromJson', () {
    test('keeps valid folders and skips malformed entries', () {
      final listing = RemoteDirectoryListing.fromJson({
        'currentPath': '/data',
        'parentPath': 42,
        'directories': [
          {'name': 'lights', 'path': '/data/lights'},
          {'name': '', 'path': '/data/flats'},
          {'name': 'missing path'},
          {'name': 7, 'path': '/data/bad-name'},
          {1: 'non-string key'},
          'not an object',
        ],
      });

      expect(listing.currentPath, '/data');
      expect(listing.parentPath, isNull);
      expect(listing.directories, hasLength(2));
      expect(listing.directories.first.name, 'lights');
      expect(listing.directories.first.path, '/data/lights');
      expect(listing.directories.last.name, '/data/flats');
    });

    test('wrong top-level field types degrade to an empty listing', () {
      final listing = RemoteDirectoryListing.fromJson({
        'currentPath': false,
        'parentPath': const <String>[],
        'directories': {'name': 'not-a-list'},
      });

      expect(listing.currentPath, isNull);
      expect(listing.parentPath, isNull);
      expect(listing.directories, isEmpty);
    });
  });
}
