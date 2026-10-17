// The Android app must report the version it actually is.
//
// Observed live on an Android 15 emulator running a build of
// apps/mobile/pubspec.yaml `version: 6.0.0+24`: Settings -> About displayed
// "Version 2.6.0", because the entry point overrode appVersionProvider with a
// hardcoded `const AppVersionInfo(version: '2.6.0', buildNumber: 6)` (and fed
// the same literal to pluginHostAppVersionOverride). Any literal here goes
// stale silently; the desktop entry reads PackageInfo, and so must this one.
//
// This is more than a cosmetic label. appVersionProvider's own contract says:
// "a misconfigured version masks the entire OTA update flow (the server
// compares against this string to decide whether to advertise a newer build)".
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/main.dart';
import 'package:package_info_plus/package_info_plus.dart';

void _mockPackage({required String version, required String buildNumber}) {
  PackageInfo.setMockInitialValues(
    appName: 'Skotiq',
    packageName: 'com.skotiq.mobile',
    version: version,
    buildNumber: buildNumber,
    buildSignature: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('loadMobileAppVersion', () {
    test(
      'reports the built package version, not a hardcoded literal',
      () async {
        _mockPackage(version: '6.0.0', buildNumber: '24');

        final info = await loadMobileAppVersion();

        expect(info.version, '6.0.0');
        expect(info.buildNumber, 24);
        expect(info.toString(), '6.0.0+24');
      },
    );

    test('tracks the package when it changes (no frozen literal)', () async {
      _mockPackage(version: '7.1.2', buildNumber: '31');

      final info = await loadMobileAppVersion();

      expect(info.version, '7.1.2');
      expect(info.buildNumber, 31);
      expect(
        info.version,
        isNot('2.6.0'),
        reason: 'the stale hardcoded value must never reappear',
      );
    });

    test(
      'an unparseable build number degrades to 0, keeping the real version',
      () async {
        _mockPackage(version: '6.0.0', buildNumber: 'not-a-number');

        final info = await loadMobileAppVersion();

        expect(
          info.version,
          '6.0.0',
          reason: 'the user-visible string stays truthful',
        );
        expect(
          info.buildNumber,
          0,
          reason: 'an honest "unknown" beats inventing a build number',
        );
      },
    );
  });
}
