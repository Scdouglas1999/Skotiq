import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/utils/device_type_parser.dart';

/// Found on live hardware, not by reading code: `GET /api/devices?deviceType=switch`
/// returned `{"devices":[]}` against a rig with three PegasusAstro switches, two
/// JustAHub switches and the simulated one. Asking for `switch_` returned all
/// six. The wire vocabulary had a Dart artefact in it — `DeviceType.switch_` is
/// spelled that way only because `switch` is a reserved word — and no client
/// would ever guess it.
void main() {
  group('parseDeviceType', () {
    test('accepts the obvious spelling of a reserved-word member', () {
      expect(parseDeviceType('switch'), DeviceType.switch_);
      expect(parseDeviceType('Switch'), DeviceType.switch_);
      expect(parseDeviceType('SWITCH'), DeviceType.switch_);
    });

    test('still accepts the literal enum name', () {
      expect(parseDeviceType('switch_'), DeviceType.switch_);
    });

    test('every device type round-trips through its own name', () {
      for (final dt in DeviceType.values) {
        expect(parseDeviceType(dt.name), dt, reason: dt.name);
      }
    });

    test('the underscore alias does not collide with another member', () {
      // If some future member were named `foo` alongside `foo_`, stripping the
      // underscore would make one unreachable. Assert the vocabulary stays
      // unambiguous rather than trusting that it does.
      final names = DeviceType.values.map((d) => d.name.toLowerCase()).toSet();
      for (final n in names) {
        if (n.endsWith('_')) {
          expect(
            names.contains(n.substring(0, n.length - 1)),
            isFalse,
            reason: 'both $n and its unsuffixed form exist',
          );
        }
      }
    });

    test('an unknown type is still unknown', () {
      expect(parseDeviceType('totalNonsense'), isNull);
      expect(parseDeviceType(''), isNull);
      // A bare underscore must not match the first suffixed member.
      expect(parseDeviceType('_'), isNull);
    });
  });
}
