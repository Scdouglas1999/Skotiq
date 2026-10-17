import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/profile_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('POST /api/profiles semantic validation', () {
    late ProviderContainer container;
    late SkotiqDatabase db;
    late ProfileHandlers handlers;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      handlers = ProfileHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<Response> save(EquipmentProfile profile) {
      return translateHandlerErrors(
        handlers.handleSaveProfile(
          Request(
            'POST',
            Uri.parse('http://localhost/api/profiles'),
            body: jsonEncode({'profile': profile.toJson()}),
          ),
        ),
      );
    }

    EquipmentProfile valid({String id = '0', String name = 'Rig A'}) {
      return EquipmentProfile(
        id: id,
        name: name,
        focalLength: 550,
        aperture: 100,
        defaultGain: 100,
        defaultOffset: 10,
        defaultCenteringExposure: 5,
        filterNames: '["R","G","B"]',
      );
    }

    test('valid payload creates a row and returns its id', () async {
      final response = await save(valid());
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'saved');

      final rows = await db.equipmentProfilesDao.getAllProfiles();
      expect(rows.length, 1);
      expect(rows.single.name, 'Rig A');
    });

    test('valid payload updates an existing row in place', () async {
      final id = await db.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(name: 'Original'),
      );

      final response = await save(valid(id: id.toString(), name: 'Renamed'));
      expect(response.statusCode, HttpStatus.ok);

      final rows = await db.equipmentProfilesDao.getAllProfiles();
      expect(rows.length, 1, reason: 'update must not create a second row');
      expect(rows.single.id, id);
      expect(rows.single.name, 'Renamed');
    });

    test('blank name is a 400 and leaves the DAO unchanged', () async {
      final response = await save(valid(name: '   '));
      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'invalid_request');
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('overlong name is a 400', () async {
      final response = await save(
        valid(name: 'x' * (EquipmentProfileLimits.nameMaxLength + 1)),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('negative optics are a 400', () async {
      final response = await save(
        EquipmentProfile(id: '0', name: 'Rig', focalLength: -1),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    // Observed live: this exact payload returns
    // `{"status":"saved","id":"7"}` / HTTP 200 against a running host and reads
    // back as f/9999999990000.00. Focal length reaches the FITS FOCALLEN card
    // and the plate-solve field-of-view estimate, so an implausible value
    // silently corrupts astrometry for the rig.
    test('implausible optics are a 400 and leave the DAO unchanged', () async {
      final response = await save(
        const EquipmentProfile(
          id: '0',
          name: 'AGENT PROBE absurd optics',
          focalLength: 999999999.0,
          aperture: 0.0001,
          focalRatio: 9999999990000.0,
          pixelSize: 99999.0,
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'invalid_request');
      expect(body['message'], contains('Focal length'));
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('each implausible optical field alone is a 400', () async {
      final cases = <String, EquipmentProfile>{
        'focal length': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          focalLength: 999999999.0,
        ),
        'aperture': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          aperture: 0.0001,
        ),
        'impossible f-ratio from in-range fields': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          focalLength: 40000,
          aperture: 2,
        ),
        'stored focal ratio': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          focalLength: 550,
          aperture: 100,
          focalRatio: 9999999990000.0,
        ),
        'pixel size': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          pixelSize: 99999.0,
        ),
        'legacy telescope focal length': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          telescopeFocalLength: 999999999.0,
        ),
        'legacy telescope aperture': const EquipmentProfile(
          id: '0',
          name: 'Rig',
          telescopeAperture: 0.0001,
        ),
      };
      for (final entry in cases.entries) {
        final response = await save(entry.value);
        expect(response.statusCode, HttpStatus.badRequest, reason: entry.key);
      }
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('a real long-focus rig still saves', () async {
      // EdgeHD 8 with a 2x barlow: 4064 mm at 203.2 mm is f/20, comfortably
      // inside the bound but far past anything a mass-market app assumes.
      final response = await save(
        const EquipmentProfile(
          id: '0',
          name: 'EdgeHD 8 + 2x',
          focalLength: 4064,
          aperture: 203.2,
          focalRatio: 20,
          pixelSize: 3.76,
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await db.equipmentProfilesDao.getAllProfiles(), hasLength(1));
    });

    test('out-of-range centering exposure is a 400', () async {
      final response = await save(
        EquipmentProfile(id: '0', name: 'Rig', defaultCenteringExposure: 90000),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('negative gain is a 400', () async {
      final response = await save(
        EquipmentProfile(id: '0', name: 'Rig', defaultGain: -5),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('duplicate filter names are a 400', () async {
      final response = await save(
        EquipmentProfile(id: '0', name: 'Rig', filterNames: '["Ha","ha"]'),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test(
      'malformed and missing positive update ids never create a row',
      () async {
        final malformed = await save(
          const EquipmentProfile(id: 'not-an-id', name: 'Rig'),
        );
        expect(malformed.statusCode, HttpStatus.badRequest);

        final missing = await save(
          const EquipmentProfile(id: '999', name: 'Rig'),
        );
        expect(missing.statusCode, HttpStatus.notFound);
        expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
      },
    );

    test('malformed filter offsets and meridian overrides are a 400', () async {
      final offsets = await save(
        const EquipmentProfile(
          id: '0',
          name: 'Rig',
          filterNames: '["L"]',
          filterFocusOffsets: '{"R":10}',
        ),
      );
      expect(offsets.statusCode, HttpStatus.badRequest);

      final meridian = await save(
        const EquipmentProfile(
          id: '0',
          name: 'Rig',
          meridianFlipOverrides: '{"maxRetries":99}',
        ),
      );
      expect(meridian.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    test('a payload missing required fields is a 400, not a 500', () async {
      final response = await translateHandlerErrors(
        handlers.handleSaveProfile(
          Request(
            'POST',
            Uri.parse('http://localhost/api/profiles'),
            body: jsonEncode({
              'profile': {'id': '1'}, // no name
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });

    // L9: the 400 must carry the underlying parse error — it is the only
    // thing that knows WHICH field was wrong. A bare 'Malformed profile
    // payload' leaves a headless-only operator unable to create a profile,
    // since there is no other path to one.
    test('a malformed payload names what went wrong', () async {
      final response = await translateHandlerErrors(
        handlers.handleSaveProfile(
          Request(
            'POST',
            Uri.parse('http://localhost/api/profiles'),
            body: jsonEncode({
              'profile': {'id': '1'}, // no name
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      final message = body['message'] as String;
      expect(message, startsWith('Malformed profile payload'));
      expect(
        message.length,
        greaterThan('Malformed profile payload'.length),
        reason: 'the underlying parse error must travel in the message',
      );
      expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
    });
  });
}
