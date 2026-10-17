import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/utils/device_id.dart';

void main() {
  group('DeviceId.parse — classification', () {
    test('classifies every known driver prefix', () {
      expect(
        DeviceId.parse('ascom:ASCOM.Camera.Simulator').kind,
        DeviceDriverKind.ascom,
      );
      expect(
        DeviceId.parse('alpaca:http://192.168.1.100:11111:camera:0').kind,
        DeviceDriverKind.alpaca,
      );
      expect(
        DeviceId.parse('indi:localhost:7624:ZWO CCD').kind,
        DeviceDriverKind.indi,
      );
      expect(DeviceId.parse('native:zwo:0').kind, DeviceDriverKind.native);
      expect(
        DeviceId.parse('simulator:fake-mount-1').kind,
        DeviceDriverKind.simulator,
      );
      expect(DeviceId.parse('sim:mount').kind, DeviceDriverKind.simulator);
      // Legacy bare simulator ids (the native bridge's `sim_` convention,
      // emitted by discovery) classify as simulator, not unknown.
      expect(DeviceId.parse('sim_camera_1').kind, DeviceDriverKind.simulator);
      expect(DeviceId.parse('sim_mount_1').kind, DeviceDriverKind.simulator);
      expect(
        DeviceId.parse('builtin_guider').kind,
        DeviceDriverKind.builtinGuider,
      );
    });

    test('legacy sim_ ids split segments on underscore', () {
      expect(DeviceId.parse('sim_camera_1').segments, <String>['camera', '1']);
    });

    test('classifies all PHD2 representations as phd2', () {
      expect(DeviceId.parse('phd2').kind, DeviceDriverKind.phd2);
      expect(DeviceId.parse('phd2_guider').kind, DeviceDriverKind.phd2);
      expect(DeviceId.parse('phd2:localhost:4400').kind, DeviceDriverKind.phd2);
      expect(
        DeviceId.parse('phd2://localhost:4400').kind,
        DeviceDriverKind.phd2,
      );
      // Case / whitespace tolerant
      expect(DeviceId.parse('  PHD2_Guider  ').kind, DeviceDriverKind.phd2);
    });

    test('empty and unclassifiable ids are unknown (parse never throws)', () {
      expect(DeviceId.parse('').kind, DeviceDriverKind.unknown);
      expect(DeviceId.parse('camera-1').kind, DeviceDriverKind.unknown);
      expect(DeviceId.parse('unknown:foo').kind, DeviceDriverKind.unknown);
    });
  });

  group('DeviceId — segments', () {
    test(
      'native multi-segment forms split into trimmed lowercase segments',
      () {
        expect(DeviceId.parse('native:touptek:Ogma:0').segments, <String>[
          'touptek',
          'ogma',
          '0',
        ]);
        expect(DeviceId.parse('native:zwo:eaf:0').segments, <String>[
          'zwo',
          'eaf',
          '0',
        ]);
        expect(DeviceId.parse('native:zwo_eaf:0').segments, <String>[
          'zwo_eaf',
          '0',
        ]);
      },
    );

    test('ascom progid is a single dot-delimited segment', () {
      expect(DeviceId.parse('ascom:ASCOM.Camera.Simulator').segments, <String>[
        'ascom.camera.simulator',
      ]);
    });

    test('alpaca and indi keep their colon segments', () {
      expect(
        DeviceId.parse('alpaca:http://host:11111:camera:0').segments,
        <String>['http', '//host', '11111', 'camera', '0'],
      );
      expect(DeviceId.parse('indi:localhost:7624:ZWO CCD').segments, <String>[
        'localhost',
        '7624',
        'zwo ccd',
      ]);
    });

    test('phd2 / builtin singletons carry no segments', () {
      expect(DeviceId.parse('phd2:localhost:4400').segments, isEmpty);
      expect(DeviceId.parse('builtin_guider').segments, isEmpty);
    });
  });

  group('DeviceId.parseStrict', () {
    test('returns a DeviceId for valid ids', () {
      expect(
        DeviceId.parseStrict('native:zwo:0').kind,
        DeviceDriverKind.native,
      );
      expect(
        DeviceId.parseStrict('phd2:localhost:4400').kind,
        DeviceDriverKind.phd2,
      );
    });

    test('throws FormatException for malformed ids (errors are a feature)', () {
      expect(() => DeviceId.parseStrict(''), throwsFormatException);
      expect(() => DeviceId.parseStrict('camera-1'), throwsFormatException);
      expect(() => DeviceId.parseStrict('unknown:foo'), throwsFormatException);
      expect(() => DeviceId.parseStrict('ascom:'), throwsFormatException);
      expect(() => DeviceId.parseStrict('native:'), throwsFormatException);
    });
  });

  group('canonical form', () {
    test('all PHD2 variants share one canonical id', () {
      const variants = [
        'phd2',
        'phd2_guider',
        'phd2:localhost:4400',
        'phd2://192.168.1.5:4400',
        'PHD2_GUIDER',
        '  phd2  ',
      ];
      for (final v in variants) {
        expect(
          DeviceId.parse(v).canonical,
          kPhd2CanonicalId,
          reason: 'canonical of "$v"',
        );
      }
    });

    test('non-phd2 canonical is trimmed + lowercased raw', () {
      expect(DeviceId.parse('  Native:ZWO:0 ').canonical, 'native:zwo:0');
      expect(
        DeviceId.parse('ascom:ASCOM.Camera.Simulator').canonical,
        'ascom:ascom.camera.simulator',
      );
    });
  });

  group('matches — PHD2 cross-variant', () {
    test('every PHD2 representation matches every other', () {
      const variants = [
        'phd2',
        'phd2_guider',
        'phd2:localhost:4400',
        'phd2://192.168.1.5:4400',
      ];
      for (final a in variants) {
        for (final b in variants) {
          expect(
            DeviceId.parse(a).matchesRaw(b),
            isTrue,
            reason: '"$a" should match "$b"',
          );
        }
      }
    });

    test('PHD2 does not match an unrelated non-PHD2 device', () {
      // NOTE: the legacy fuzzy fallback is loose — it WILL relate
      // 'phd2_guider' to any id whose tokens contain "guider" (e.g.
      // 'ascom:ASCOM.Guider.X'). That over-match is preserved behavior and
      // is the whole reason PHD2 has a canonical short-circuit. Here we use
      // ids that share no tokens to assert non-PHD2 ids stay distinct.
      expect(
        DeviceId.parse('phd2:localhost:4400').matchesRaw('native:zwo:0'),
        isFalse,
      );
      expect(DeviceId.parse('phd2_guider').matchesRaw('native:qhy:5'), isFalse);
    });
  });

  group('matches — canonical equality', () {
    test('identical ids match (case / whitespace insensitive)', () {
      expect(DeviceId.parse('native:zwo:0').matchesRaw('native:zwo:0'), isTrue);
      expect(
        DeviceId.parse(' NATIVE:ZWO:0 ').matchesRaw('native:zwo:0'),
        isTrue,
      );
    });
  });

  group('matches — legacy fuzzy fallback (preserved semantics)', () {
    test('ZWO EAF model match across id formats', () {
      // "ZWO EAF" display name vs the composite native id — the historical
      // case the fuzzy "one contains the other" branch was built for.
      expect(deviceIdsMatch('ZWO EAF', 'native:zwo_eaf:0'), isTrue);
    });

    test('numbered model identifiers must share a token', () {
      // Same model number → match.
      expect(deviceIdsMatch('ASI294MC Pro', 'ZWO ASI294MC Pro'), isTrue);
      // Different model numbers → no match (distinguishing branch).
      expect(deviceIdsMatch('ASI294', 'ASI533'), isFalse);
    });

    test('normalized alphanumeric equality matches', () {
      expect(
        deviceIdsMatch('ASCOM.EQMOD.Telescope', 'ascomeqmodtelescope'),
        isTrue,
      );
    });

    test('completely unrelated ids do not match', () {
      expect(
        deviceIdsMatch('native:qhy:0', 'ascom:Celestron.Focuser.X'),
        isFalse,
      );
    });

    test('token-based 50% threshold', () {
      // "ZWO ASIAIR" vs "asiair zwo": both two-token sets, both tokens
      // overlap → passes the legacy >=50% token threshold.
      expect(deviceIdsMatch('ZWO ASIAIR', 'asiair zwo'), isTrue);
      // A single shared token out of three is below the 50% threshold and
      // shares no numbered model → no match (preserved legacy result).
      expect(deviceIdsMatch('ZWO Filter Wheel', 'native:zwo_efw:0'), isFalse);
    });
  });

  group('canonicalGuiderId free function', () {
    test('collapses PHD2, preserves everything else verbatim', () {
      expect(canonicalGuiderId('phd2'), kPhd2CanonicalId);
      expect(canonicalGuiderId('phd2_guider'), kPhd2CanonicalId);
      expect(canonicalGuiderId('phd2:host:4400'), kPhd2CanonicalId);
      expect(canonicalGuiderId('phd2://host:4400'), kPhd2CanonicalId);
      // Non-PHD2 returned untouched (original case preserved).
      expect(canonicalGuiderId('native:ZWO:0'), 'native:ZWO:0');
      expect(canonicalGuiderId('ascom:ASCOM.Guider.X'), 'ascom:ASCOM.Guider.X');
    });
  });

  group('isPhd2DeviceId', () {
    test('matches strict PHD2 forms only', () {
      expect(isPhd2DeviceId('phd2'), isTrue);
      expect(isPhd2DeviceId('phd2_guider'), isTrue);
      expect(isPhd2DeviceId('phd2:localhost:4400'), isTrue);
      expect(isPhd2DeviceId('phd2://localhost:4400'), isTrue);
      expect(isPhd2DeviceId('  PHD2  '), isTrue);
      expect(isPhd2DeviceId('native:zwo:0'), isFalse);
      expect(isPhd2DeviceId('phd 2'), isFalse); // space form is not a strict id
    });
  });

  group('friendlyNameFromDeviceId', () {
    test('native accessory ids', () {
      expect(friendlyNameFromDeviceId('native:zwo_efw:0'), 'ZWO EFW 0');
      expect(friendlyNameFromDeviceId('native:zwo_efw:3'), 'ZWO EFW 3');
      expect(
        friendlyNameFromDeviceId('native:qhy_cfw:CAM_A'),
        'QHY CFW (CAM_A)',
      );
      expect(
        friendlyNameFromDeviceId('native:fli_fw:anything'),
        'FLI Filter Wheel',
      );
    });

    test('ascom keeps last two progid segments', () {
      expect(
        friendlyNameFromDeviceId('ascom:ASCOM.EFWmini.FilterWheel'),
        'EFWmini FilterWheel',
      );
      // Single-segment progid falls back to the raw progid.
      expect(friendlyNameFromDeviceId('ascom:OnlyOne'), 'OnlyOne');
    });

    test('alpaca and unrecognized ids', () {
      expect(
        friendlyNameFromDeviceId('alpaca:http://host:11111:filterwheel:0'),
        'Alpaca Filter Wheel',
      );
      expect(
        friendlyNameFromDeviceId(
          'alpaca:http://host:11111:observingconditions:0',
        ),
        'Alpaca Weather Station',
      );
      expect(
        friendlyNameFromDeviceId('alpaca:http://host:11111:safetymonitor:0'),
        'Alpaca Safety Monitor',
      );
      expect(
        friendlyNameFromDeviceId('alpaca:http://host:11111:camera:0'),
        'Alpaca Camera',
      );
      // Unknown id returns the id unchanged.
      expect(friendlyNameFromDeviceId('native:zwo:0'), 'native:zwo:0');
    });
  });

  group('isValidDeviceIdFormat (preserved)', () {
    test('accepts known prefixes and singletons', () {
      expect(isValidDeviceIdFormat('ascom:ASCOM.ZWO.Camera'), isTrue);
      expect(isValidDeviceIdFormat('native:zwo:0'), isTrue);
      expect(isValidDeviceIdFormat('phd2:localhost:4400'), isTrue);
      expect(isValidDeviceIdFormat('phd2'), isTrue);
      expect(isValidDeviceIdFormat('phd2_guider'), isTrue);
      expect(isValidDeviceIdFormat('builtin_guider'), isTrue);
      // Legacy bare simulator ids must be connectable (the native bridge keys
      // its simulators off the `sim_` prefix and discovery emits them).
      expect(isValidDeviceIdFormat('sim_camera_1'), isTrue);
      expect(isValidDeviceIdFormat('sim_mount_1'), isTrue);
    });

    test('rejects malformed ids', () {
      expect(isValidDeviceIdFormat(''), isFalse);
      expect(isValidDeviceIdFormat('camera-1'), isFalse);
      expect(isValidDeviceIdFormat('unknown:foo'), isFalse);
      expect(isValidDeviceIdFormat('ascom:'), isFalse);
      expect(isValidDeviceIdFormat('native:'), isFalse);
    });
  });
}
