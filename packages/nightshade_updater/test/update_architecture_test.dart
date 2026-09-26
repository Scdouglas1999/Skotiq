// The architecture a host reports is how it finds its own manifest, so this
// mapping has to agree with the names the release workflow gives them. A
// phone that reports `arm` where CI wrote `arm64` finds nothing and reports
// itself permanently up to date.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_updater/src/services/update_compatibility.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ABI name to manifest architecture', () {
    test('Android ABIs match the names the release workflow uses', () {
      // These three pairs must stay in step with ARCH_FOR_ABI in
      // .github/workflows/release.yml, which names the manifests.
      expect(
        updateArchitectureForAbiName(Abi.androidArm64.toString()),
        'arm64',
      );
      expect(updateArchitectureForAbiName(Abi.androidArm.toString()), 'arm');
      expect(updateArchitectureForAbiName(Abi.androidX64.toString()), 'x64');
    });

    test('a 64-bit ARM host is never read as the 32-bit build', () {
      // `androidArm64` ends with both `arm64` and `arm`; matching `arm` first
      // would hand every modern phone the armeabi-v7a package.
      expect(updateArchitectureForAbiName('androidArm64'), isNot('arm'));
      expect(updateArchitectureForAbiName('linuxArm64'), 'arm64');
      expect(updateArchitectureForAbiName('macosArm64'), 'arm64');
    });

    test('desktop ABIs map to the names CI builds', () {
      expect(updateArchitectureForAbiName(Abi.linuxX64.toString()), 'x64');
      expect(updateArchitectureForAbiName(Abi.windowsX64.toString()), 'x64');
      expect(updateArchitectureForAbiName('linuxIA32'), 'x86');
      expect(updateArchitectureForAbiName('linuxRiscv64'), 'riscv64');
    });

    test('an unknown ABI falls through to the normalizer, not a guess', () {
      expect(
        updateArchitectureForAbiName('fuchsiaSomethingNew'),
        'fuchsiasomethingnew',
      );
    });

    test('this host reports an architecture the manifests could name', () {
      expect(
        currentUpdateArchitecture(),
        isNot(isEmpty),
        reason: 'a host with no architecture can never match a manifest',
      );
    });
  });

  group('platform normalization', () {
    test('the names CI writes are the names hosts report', () {
      expect(normalizeUpdatePlatform('windows'), 'windows');
      expect(normalizeUpdatePlatform('linux'), 'linux');
      expect(normalizeUpdatePlatform('android'), 'android');
      // Dart reports these older spellings on some hosts.
      expect(normalizeUpdatePlatform('win32'), 'windows');
      expect(normalizeUpdatePlatform('darwin'), 'macos');
    });
  });

  group('release workflow', () {
    test('every platform build compiles in the update public key', () {
      // A build verifies manifests only against the key compiled into it via
      // --dart-define. A platform built without it can authenticate nothing,
      // so provisioning the signing key would switch OTA on for that platform
      // in name only: every download refused, forever, with no way to fix it
      // short of a manual reinstall.
      final workflow = File(
        p.join(
          Directory.current.path,
          '..',
          '..',
          '.github',
          'workflows',
          'release.yml',
        ),
      ).readAsStringSync();
      for (final target in ['apk', 'linux', 'windows']) {
        final builds = RegExp(
          'flutter build $target\\b[^\\n]*',
        ).allMatches(workflow).map((m) => m.group(0)!).toList();
        expect(
          builds,
          isNotEmpty,
          reason: 'release.yml has no `flutter build $target` step',
        );
        for (final line in builds) {
          expect(
            line,
            contains('--dart-define=NIGHTSHADE_UPDATE_PUBLIC_KEY='),
            reason: '`$line` builds without the update public key',
          );
        }
      }
    });
  });
}
