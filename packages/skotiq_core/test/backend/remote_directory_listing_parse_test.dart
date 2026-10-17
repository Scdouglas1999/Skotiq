// Parse-layer cover for RemoteDirectoryListing / RemoteDirectoryEntry.
//
// The picker feeds whatever the host returns straight through fromJson. A lazy
// `.cast<Map<String, dynamic>>()` over `directories` would throw at iteration
// time on the first non-object element and drop the entire browse response;
// a numeric `currentPath` would throw on the `as String` cast. These assert
// that malformed frames degrade gracefully (well-formed folders survive, bad
// fields are rejected so the picker cannot expose an empty/invalid destination)
// and that legitimate root listings — null currentPath/parentPath — round-trip.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

void main() {
  group('RemoteDirectoryListing.fromJson', () {
    test('parses a well-formed listing', () {
      final listing = RemoteDirectoryListing.fromJson({
        'currentPath': '/data',
        'parentPath': '/',
        'directories': [
          {'name': 'alpha', 'path': '/data/alpha'},
          {'name': 'beta', 'path': '/data/beta'},
        ],
      });

      expect(listing.currentPath, '/data');
      expect(listing.parentPath, '/');
      expect(listing.directories, hasLength(2));
      expect(listing.directories.first.name, 'alpha');
      expect(listing.directories.first.path, '/data/alpha');
    });

    test('root listing keeps null currentPath/parentPath', () {
      final listing = RemoteDirectoryListing.fromJson({
        'currentPath': null,
        'parentPath': null,
        'directories': [
          {'name': 'C:', 'path': 'C:/'},
        ],
      });

      expect(listing.currentPath, isNull);
      expect(listing.parentPath, isNull);
      expect(listing.directories.single.path, 'C:/');
    });

    test('skips non-object directory entries instead of throwing', () {
      final listing = RemoteDirectoryListing.fromJson({
        'currentPath': '/data',
        'directories': [
          {'name': 'good', 'path': '/data/good'},
          'not-an-object',
          42,
          null,
          {'name': 'also-good', 'path': '/data/also-good'},
        ],
      });

      expect(listing.directories.map((e) => e.path), [
        '/data/good',
        '/data/also-good',
      ]);
    });

    test('rejects wrong-typed entries and tolerates non-string paths', () {
      final listing = RemoteDirectoryListing.fromJson({
        'currentPath': 12345, // numeric — must not throw
        'parentPath': ['nope'],
        'directories': [
          {'name': 7, 'path': false},
        ],
      });

      expect(listing.currentPath, isNull);
      expect(listing.parentPath, isNull);
      expect(listing.directories, isEmpty);
    });

    test('tolerates a missing or non-list directories field', () {
      expect(RemoteDirectoryListing.fromJson({}).directories, isEmpty);
      expect(
        RemoteDirectoryListing.fromJson({'directories': 'oops'}).directories,
        isEmpty,
      );
    });
  });
}
