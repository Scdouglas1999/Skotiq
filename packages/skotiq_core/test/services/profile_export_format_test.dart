// An equipment-profile export identifies itself, and every import rejection is
// prose the operator can act on.
//
// A bare map of profile fields with no marker of what it is fails deep inside
// field parsing for anything else, showing the raw Dart exception — "Import
// failed: FormatException: Unexpected character (at character 1)" for a text
// file, "Import failed: FormatException: Profile name must be a non-empty
// string" for unrelated JSON.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  Map<String, dynamic> exported() => ProfileExportData.fromModel(
    const EquipmentProfileModel(
      id: 3,
      name: 'Widefield',
      focalLength: 530,
      aperture: 106,
    ),
  ).toJson();

  group('export envelope', () {
    test('carries a format marker and a version', () {
      final doc = profileExportEnvelope([exported()]);
      expect(doc['format'], 'skotiq.equipment-profile');
      expect(doc['version'], kProfileExportVersion);
      expect((doc['profiles'] as List), hasLength(1));
    });

    test('round-trips through the reader', () {
      final json = jsonEncode(profileExportEnvelope([exported()]));
      final profiles = profilesFromExportDocument(json);
      expect(profiles, hasLength(1));
      expect(parseExportedProfile(profiles.first, index: 0).name, 'Widefield');
    });
  });

  group('rejection messages', () {
    String messageFor(String document) {
      try {
        profilesFromExportDocument(document);
      } on ProfileImportException catch (e) {
        return e.message;
      }
      fail('the document was accepted: $document');
    }

    test('a non-JSON file says so instead of naming a character offset', () {
      final message = messageFor('this is my observing log, not a profile');
      expect(message, contains('not a Skotiq equipment profile'));
      expect(message, isNot(contains('FormatException')));
      expect(message, isNot(contains('character')));
    });

    test('unrelated JSON is refused as not a profile', () {
      final message = messageFor('{"brightness": 3, "theme": "dark"}');
      expect(message, contains('no profile data'));
      expect(message, isNot(contains('FormatException')));
    });

    test('another app\'s export is named', () {
      final message = messageFor(
        jsonEncode({'format': 'acme.rig', 'profiles': <dynamic>[]}),
      );
      expect(message, contains('"acme.rig"'));
    });

    test('a newer export format is refused with what to do about it', () {
      final message = messageFor(
        jsonEncode({
          'format': kProfileExportFormat,
          'version': kProfileExportVersion + 1,
          'profiles': [exported()],
        }),
      );
      expect(message, contains('newer version of Skotiq'));
      expect(message, contains('Update Skotiq'));
    });

    test('a damaged entry names the profile, not the Dart exception', () {
      final broken = exported()..['focalLength'] = -5;
      try {
        parseExportedProfile(broken, index: 0);
        fail('a negative focal length must be refused');
      } on ProfileImportException catch (e) {
        expect(e.message, contains('"Widefield"'));
        expect(e.message, isNot(contains('FormatException')));
      }
    });

    test('an unnamed entry is identified by position', () {
      try {
        parseExportedProfile(<String, dynamic>{'focalLength': 500}, index: 2);
        fail('a nameless profile must be refused');
      } on ProfileImportException catch (e) {
        expect(e.message, contains('entry 3'));
      }
    });
  });

  group('another Skotiq document is not mistaken for a profile', () {
    // The picker filters to *.json and a sequence export lives in the same
    // folder. Accepting any document with a top-level `name` imports a profile
    // named after the sequence with a 0 mm focal length and reports success.
    test('a sequence export is refused and named', () {
      try {
        profilesFromExportDocument(
          jsonEncode({
            'schemaVersion': 1,
            'version': '2.0',
            'name': 'M31 all-night',
            'description': 'LRGB',
            'rootNodeId': 'root',
            'isTemplate': false,
            'nodes': <String, dynamic>{},
          }),
        );
        fail('a sequence export must not import as a profile');
      } on ProfileImportException catch (e) {
        expect(e.message, contains('Skotiq sequence'));
        expect(e.message, contains('Sequencer'));
      }
    });

    test('an unrelated document with a name carries no profile data', () {
      try {
        profilesFromExportDocument(
          jsonEncode({'name': 'Winter targets', 'targets': <dynamic>[]}),
        );
        fail('an unrelated document must not import as a profile');
      } on ProfileImportException catch (e) {
        expect(e.message, contains('no profile data'));
      }
    });

    test('a field of the wrong type is prose, not a Dart type error', () {
      final broken = exported()..['description'] = 42;
      try {
        parseExportedProfile(broken, index: 0);
        fail('a numeric description must be refused');
      } on ProfileImportException catch (e) {
        expect(e.message, contains('"Widefield"'));
        expect(e.message, contains('description'));
        expect(e.message, isNot(contains('subtype')));
        expect(e.message, isNot(contains('type cast')));
      }
    });

    test('a non-numeric focal length is prose, not a Dart type error', () {
      final broken = exported()..['focalLength'] = '530mm';
      try {
        parseExportedProfile(broken, index: 0);
        fail('a textual focal length must be refused');
      } on ProfileImportException catch (e) {
        expect(e.message, contains('focalLength'));
        expect(e.message, isNot(contains('subtype')));
      }
    });
  });

  group('files written by older builds still import', () {
    test('a bare single-profile map', () {
      final profiles = profilesFromExportDocument(jsonEncode(exported()));
      expect(profiles, hasLength(1));
      expect(parseExportedProfile(profiles.first, index: 0).name, 'Widefield');
    });

    test('the pre-envelope batch export', () {
      final json = jsonEncode({
        'version': 2,
        'exportDate': '2026-01-01T00:00:00.000',
        'profiles': [exported()],
      });
      expect(profilesFromExportDocument(json), hasLength(1));
    });

    test('a bare list of profiles', () {
      expect(
        profilesFromExportDocument(jsonEncode([exported()])),
        hasLength(1),
      );
    });
  });
}
