import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/models/troubleshooter/connection_diagnostic.dart';

void main() {
  group('diagnoseConnectionFailure — classification by marker', () {
    test('ASCOM RPC server unavailable HRESULT maps to driver', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'CCD: 0x800706BA The RPC server is unavailable',
      );
      expect(d.category, DiagnosticCategory.driver);
    });

    test('"RPC server unavailable" text maps to driver', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.ascom,
        rawError: 'RPC server unavailable',
      );
      expect(d.category, DiagnosticCategory.driver);
    });

    test('class-not-registered HRESULT maps to driver', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'CoCreateInstance failed: 0x80040154',
      );
      expect(d.category, DiagnosticCategory.driver);
    });

    test('"access is denied" maps to permission', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'Open failed: Access is denied.',
      );
      expect(d.category, DiagnosticCategory.permission);
    });

    test('HRESULT 0x80070005 maps to permission', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'Connect threw 0x80070005',
      );
      expect(d.category, DiagnosticCategory.permission);
    });

    test('permission wins over driver when both markers present', () {
      // "access is denied" is checked before driver markers; an RPC error
      // that is fundamentally an access problem should route to permission.
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'RPC server unavailable: access is denied 0x80070005',
      );
      expect(d.category, DiagnosticCategory.permission);
    });

    test('alpaca + connection refused maps to network', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.alpaca,
        rawError: 'Connection refused (192.168.1.50:11111)',
      );
      expect(d.category, DiagnosticCategory.network);
    });

    test('indi + timed out maps to network', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.indi,
        rawError: 'connect: operation timed out',
      );
      expect(d.category, DiagnosticCategory.network);
    });

    test('indi + unreachable maps to network', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.focuser,
        driverType: DriverType.indi,
        rawError: 'No route to host — host unreachable',
      );
      expect(d.category, DiagnosticCategory.network);
    });

    test(
      'native + timed out does NOT map to network (driver/usb territory)',
      () {
        // A local USB device timing out is not a host/port/firewall problem.
        final d = diagnoseConnectionFailure(
          deviceType: DeviceType.camera,
          driverType: DriverType.native,
          rawError: 'USB transfer timed out',
        );
        expect(d.category, isNot(DiagnosticCategory.network));
      },
    );

    test('"not found" maps to usb', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'Camera not found',
      );
      expect(d.category, DiagnosticCategory.usb);
    });

    test('"no devices" maps to usb', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'Discovery returned no devices',
      );
      expect(d.category, DiagnosticCategory.usb);
    });

    test('empty discovery (empty rawError) maps to usb', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: '',
      );
      expect(d.category, DiagnosticCategory.usb);
    });

    test('null rawError (no discovery) maps to usb', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: null,
      );
      expect(d.category, DiagnosticCategory.usb);
    });

    test('invalid value HRESULT maps to configuration', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.ascom,
        rawError: 'InvalidValueException 0x80040401: COM port not set',
      );
      expect(d.category, DiagnosticCategory.configuration);
    });

    test('value-not-set HRESULT maps to configuration', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.focuser,
        driverType: DriverType.ascom,
        rawError: '0x80040402 ValueNotSetException',
      );
      expect(d.category, DiagnosticCategory.configuration);
    });

    test('unrecognized error maps to unknown', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'gremlin flux capacitor overvolted',
      );
      expect(d.category, DiagnosticCategory.unknown);
    });

    // The built-in guider is a SOFTWARE guider: it reuses the imaging camera
    // and pulses the mount, so it has no cable, no power switch and no vendor
    // driver. Its preflight names the exact missing profile value, and the
    // dialog must route that to a configuration cause rather than the
    // reseat-a-cable playbook.
    group('built-in guider preflight', () {
      const focalLengthError =
          'Failed to connect built-in guider: Operation failed: Built-in '
          'guider requires positive guide focal length and camera pixel size '
          '(focal_length_mm=0, pixel_size_x_um=3.76, pixel_size_y_um=3.76)';

      ConnectionDiagnosis diagnose(String raw) => diagnoseConnectionFailure(
        deviceType: DeviceType.guider,
        driverType: DriverType.native,
        rawError: raw,
      );

      test('a zero focal length is a configuration cause, not unknown', () {
        final d = diagnose(focalLengthError);
        expect(d.category, DiagnosticCategory.configuration);
        expect(d.plainLanguage, isNot(contains("couldn't pin down")));
      });

      test('the steps name the focal length and never a cable or power', () {
        final steps = _stepsText(diagnose(focalLengthError)).toLowerCase();
        expect(steps, contains('focal length'));
        expect(
          steps,
          isNot(contains('cable')),
          reason: 'the built-in guider has no cable to reseat',
        );
        expect(steps, isNot(contains('power')));
        expect(steps, isNot(contains('restart skotiq')));
      });

      test('the missing-profile variant is classified the same way', () {
        final d = diagnose(
          'Operation failed: Built-in guider requires an active profile with '
          'a guide focal length',
        );
        expect(d.category, DiagnosticCategory.configuration);
        expect(_allText(d).toLowerCase(), contains('focal length'));
      });

      test(
        'the unassigned-camera variant names the assignment, not a cable',
        () {
          final steps = _stepsText(
            diagnose(
              'Operation failed: Built-in guider requires a connected camera in '
              'the active profile',
            ),
          ).toLowerCase();
          expect(steps, contains('profile'));
          expect(steps, isNot(contains('cable')));
        },
      );

      test('a real ASCOM guider failure still gets the driver playbook', () {
        // Anti-inversion: the new rule must not swallow genuine hardware
        // failures on the same device type.
        final d = diagnoseConnectionFailure(
          deviceType: DeviceType.guider,
          driverType: DriverType.ascom,
          rawError: '0x800706ba RPC server unavailable',
        );
        expect(d.category, DiagnosticCategory.driver);
      });
    });

    test('classification is case-insensitive', () {
      final lower = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'access is denied',
      );
      final upper = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'ACCESS IS DENIED',
      );
      expect(lower.category, DiagnosticCategory.permission);
      expect(upper.category, DiagnosticCategory.permission);
    });
  });

  group('diagnoseConnectionFailure — raw error is always carried through', () {
    test('recognized error preserves raw verbatim', () {
      const raw = 'CCD: 0x800706BA The RPC server is unavailable';
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: raw,
      );
      expect(d.rawError, raw);
    });

    test('unknown error preserves raw verbatim', () {
      const raw = 'gremlin flux capacitor overvolted';
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: raw,
      );
      expect(d.category, DiagnosticCategory.unknown);
      expect(d.rawError, raw);
    });

    test('null raw is carried through as null', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: null,
      );
      expect(d.rawError, isNull);
    });
  });

  group(
    'diagnoseConnectionFailure — every category yields non-empty steps',
    () {
      for (final category in DiagnosticCategory.values) {
        test('$category produces concrete steps', () {
          // Drive each category via a representative input.
          final d = _diagnosisForCategory(category);
          expect(d.category, category);
          expect(d.steps, isNotEmpty);
          expect(d.steps.length, greaterThanOrEqualTo(3));
          expect(d.steps.length, lessThanOrEqualTo(6));
          for (final step in d.steps) {
            expect(step.instruction.trim(), isNotEmpty);
          }
          expect(d.headline.trim(), isNotEmpty);
          expect(d.plainLanguage.trim(), isNotEmpty);
        });
      }

      test('unknown still yields non-empty steps and preserves raw', () {
        const raw = 'completely novel failure mode';
        final d = diagnoseConnectionFailure(
          deviceType: DeviceType.mount,
          driverType: DriverType.indi,
          rawError: raw,
        );
        expect(d.category, DiagnosticCategory.unknown);
        expect(d.steps, isNotEmpty);
        expect(d.rawError, raw);
      });
    },
  );

  group('diagnoseConnectionFailure — device-specific copy', () {
    test('camera USB steps mention 12V power supply; mount does not', () {
      final camera = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'camera not found',
      );
      final mount = diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.native,
        rawError: 'mount not found',
      );

      final cameraText = _allText(camera);
      final mountText = _allText(mount);

      expect(cameraText, contains('12V'));
      expect(cameraText, contains('camera'));
      expect(mountText, isNot(contains('12V')));
      expect(mountText, contains('mount'));
      // The mount-specific power copy should appear instead.
      expect(mountText.toLowerCase(), contains('mount power supply'));
    });

    test('camera vs mount produce different step copy', () {
      final camera = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'not found',
      );
      final mount = diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.native,
        rawError: 'not found',
      );
      expect(_allText(camera), isNot(equals(_allText(mount))));
    });

    test('filter wheel noun appears in copy', () {
      final fw = diagnoseConnectionFailure(
        deviceType: DeviceType.filterWheel,
        driverType: DriverType.native,
        rawError: 'not found',
      );
      expect(_allText(fw).toLowerCase(), contains('filter wheel'));
    });
  });

  group('diagnoseConnectionFailure — driver-specific copy', () {
    test('native USB steps mention reinstalling the SDK/driver', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'camera not found',
      );
      expect(_allText(d).toLowerCase(), contains('sdk'));
    });

    test('ascom USB steps mention the ASCOM driver instead of the SDK', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'camera not found',
      );
      final text = _allText(d);
      expect(text, contains('ASCOM'));
    });

    test('alpaca network steps mention the default port 11111', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.alpaca,
        rawError: 'connection refused',
      );
      final text = _allText(d);
      expect(text, contains('11111'));
      expect(text, contains('firewall'));
      expect(text, contains('Alpaca'));
    });

    test('indi network steps mention the default port 7624', () {
      final d = diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.indi,
        rawError: 'connection refused',
      );
      final text = _allText(d);
      expect(text, contains('7624'));
      expect(text, contains('INDI'));
    });
  });

  group('diagnoseConnectionFailure — determinism', () {
    test('identical inputs produce equal diagnoses', () {
      ConnectionDiagnosis make() => diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.alpaca,
        rawError: 'Connection refused (host:11111)',
      );
      final a = make();
      final b = make();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.steps, equals(b.steps));
    });

    test('repeated calls across all categories are stable', () {
      for (final device in DeviceType.values) {
        for (final driver in DriverType.values) {
          for (final raw in const [
            null,
            '',
            'access is denied',
            '0x800706ba',
            'connection refused',
            'not found',
            'invalid value 0x80040401',
            'unrecognized gobbledygook',
          ]) {
            final first = diagnoseConnectionFailure(
              deviceType: device,
              driverType: driver,
              rawError: raw,
            );
            final second = diagnoseConnectionFailure(
              deviceType: device,
              driverType: driver,
              rawError: raw,
            );
            expect(
              first,
              equals(second),
              reason: 'device=$device driver=$driver raw=$raw',
            );
          }
        }
      }
    });
  });

  group('RemediationStep & ConnectionDiagnosis value semantics', () {
    test('RemediationStep equality and hashCode', () {
      const a = RemediationStep(instruction: 'do x', detail: 'because y');
      const b = RemediationStep(instruction: 'do x', detail: 'because y');
      const c = RemediationStep(instruction: 'do x');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('ConnectionDiagnosis inequality on differing steps', () {
      const base = ConnectionDiagnosis(
        category: DiagnosticCategory.unknown,
        headline: 'h',
        plainLanguage: 'p',
        steps: [RemediationStep(instruction: 'a')],
        rawError: 'r',
      );
      const differentSteps = ConnectionDiagnosis(
        category: DiagnosticCategory.unknown,
        headline: 'h',
        plainLanguage: 'p',
        steps: [RemediationStep(instruction: 'b')],
        rawError: 'r',
      );
      expect(base, isNot(equals(differentSteps)));
    });
  });
}

/// Returns a diagnosis guaranteed to land in [category] using a representative
/// marker for each. Keeps the per-category coverage test honest.
ConnectionDiagnosis _diagnosisForCategory(DiagnosticCategory category) {
  switch (category) {
    case DiagnosticCategory.usb:
      return diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'camera not found',
      );
    case DiagnosticCategory.driver:
      return diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: '0x800706ba RPC server unavailable',
      );
    case DiagnosticCategory.permission:
      return diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'access is denied',
      );
    case DiagnosticCategory.network:
      return diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.alpaca,
        rawError: 'connection refused',
      );
    case DiagnosticCategory.configuration:
      return diagnoseConnectionFailure(
        deviceType: DeviceType.mount,
        driverType: DriverType.ascom,
        rawError: 'invalid value 0x80040401',
      );
    case DiagnosticCategory.unknown:
      return diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: 'totally novel failure',
      );
  }
}

/// Concatenates only the remediation STEPS — the "what do I do now" list the
/// operator acts on, separate from the explanation above it.
String _stepsText(ConnectionDiagnosis d) {
  final buffer = StringBuffer();
  for (final step in d.steps) {
    buffer
      ..writeln(step.instruction)
      ..writeln(step.detail ?? '');
  }
  return buffer.toString();
}

/// Concatenates all user-facing copy of a diagnosis for substring assertions.
String _allText(ConnectionDiagnosis d) {
  final buffer = StringBuffer()
    ..writeln(d.headline)
    ..writeln(d.plainLanguage);
  for (final step in d.steps) {
    buffer
      ..writeln(step.instruction)
      ..writeln(step.detail ?? '');
  }
  return buffer.toString();
}
