import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_service.dart';

void main() {
  UpdateManifest manifest({
    String version = '2.1.0',
    int buildNumber = 42,
    String? minVersion,
    String platform = 'windows',
    String arch = 'x64',
  }) => UpdateManifest(
    version: version,
    buildNumber: buildNumber,
    releaseDate: DateTime.utc(2026, 5, 25),
    platform: platform,
    arch: arch,
    minVersion: minVersion,
    files: const {},
    totalSize: 0,
    compressedSize: 0,
    downloadUrl: 'https://example.invalid/skotiq.zip',
  );

  group('canUpgradeFrom version-component gating', () {
    test('from "2.0" with minVersion "2.0.5" is blocked (no fail-open)', () {
      expect(manifest(minVersion: '2.0.5').canUpgradeFrom('2.0'), isFalse);
    });

    test(
      'from "2.0.5" with minVersion "2.0.5" is allowed (equal -> allow)',
      () {
        expect(manifest(minVersion: '2.0.5').canUpgradeFrom('2.0.5'), isTrue);
      },
    );

    test('from "2.1" with minVersion "2.0.5" is allowed (strictly newer)', () {
      expect(manifest(minVersion: '2.0.5').canUpgradeFrom('2.1'), isTrue);
    });

    test(
      'from "2.0.5.1" with minVersion "2.0.5" is allowed (longer, prefix equal)',
      () {
        expect(manifest(minVersion: '2.0.5').canUpgradeFrom('2.0.5.1'), isTrue);
      },
    );

    test('minVersion == null means no gate', () {
      expect(manifest(minVersion: null).canUpgradeFrom('1.0.0'), isTrue);
      expect(manifest(minVersion: null).canUpgradeFrom('0.0'), isTrue);
    });
  });

  group('malformed version rejection', () {
    test('manifest versions are not coerced into zero components', () {
      expect(
        () => manifest(version: '2.x.0').isNewerThan('2.0.0'),
        throwsFormatException,
      );
    });

    test('installed versions are validated before comparison', () {
      expect(
        () => manifest(version: '2.1.0').isNewerThan('not-a-version'),
        throwsFormatException,
      );
    });

    test('minimum versions are validated before upgrade gating', () {
      expect(
        () => manifest(minVersion: '2..0').canUpgradeFrom('2.1.0'),
        throwsFormatException,
      );
    });
  });

  group('semver ordering with prerelease tags', () {
    test('4.10.0 is newer than 4.9.0 (numeric, not lexical)', () {
      expect(manifest(version: '4.10.0').isNewerThan('4.9.0'), isTrue);
      expect(manifest(version: '4.9.0').isNewerThan('4.10.0'), isFalse);
    });

    test('a prerelease is older than its release core', () {
      expect(manifest(version: '2.1.0-beta.1').isNewerThan('2.1.0'), isFalse);
      expect(manifest(version: '2.1.0').isNewerThan('2.1.0-beta.1'), isTrue);
    });

    test('a later prerelease outranks an earlier one', () {
      expect(
        manifest(version: '2.1.0-beta.2').isNewerThan('2.1.0-beta.1'),
        isTrue,
      );
      expect(
        manifest(version: '2.1.0-beta.1').isNewerThan('2.1.0-beta.2'),
        isFalse,
      );
    });

    test('release core outranks a prerelease regardless of build tiebreak', () {
      expect(
        manifest(
          version: '2.1.0',
          buildNumber: 1,
        ).isNewerBuildThan('2.1.0-beta.9', 99),
        isTrue,
      );
    });

    test(
      'equal version+build tiebreak still preserved across prerelease fix',
      () {
        expect(
          manifest(
            version: '2.1.0',
            buildNumber: 5,
          ).isNewerBuildThan('2.1.0', 4),
          isTrue,
        );
        expect(
          manifest(
            version: '2.1.0',
            buildNumber: 4,
          ).isNewerBuildThan('2.1.0', 4),
          isFalse,
        );
      },
    );
  });

  group('isNewerBuildThan same-semver build gating', () {
    test('newer build at equal version is newer', () {
      expect(
        manifest(version: '2.0.0', buildNumber: 5).isNewerBuildThan('2.0.0', 4),
        isTrue,
      );
    });

    test('identical version+build is not newer (no self-update loop)', () {
      expect(
        manifest(version: '2.0.0', buildNumber: 4).isNewerBuildThan('2.0.0', 4),
        isFalse,
      );
    });

    test('strictly newer semver is newer regardless of build', () {
      expect(
        manifest(
          version: '2.1.0',
          buildNumber: 1,
        ).isNewerBuildThan('2.0.0', 99),
        isTrue,
      );
    });

    test('older semver is not newer even with a higher build', () {
      expect(
        manifest(
          version: '1.9.0',
          buildNumber: 99,
        ).isNewerBuildThan('2.0.0', 1),
        isFalse,
      );
    });

    test('equal version with lower build is not newer', () {
      expect(
        manifest(version: '2.0.0', buildNumber: 3).isNewerBuildThan('2.0.0', 4),
        isFalse,
      );
    });

    test('isNewerThan keeps its semver-only contract (ignores build)', () {
      expect(manifest(version: '2.0.0').isNewerThan('2.0.0'), isFalse);
      expect(manifest(version: '2.0.1').isNewerThan('2.0.0'), isTrue);
    });
  });

  group('checkForUpdates build-aware availability', () {
    // Routes /api/version and the manifest URL through an in-memory mock so
    // the build-gating branch is exercised without network or disk.
    UpdateService serviceFor(
      UpdateManifest served, {
      required String currentVersion,
      required int currentBuildNumber,
      String? channelVersion,
      String manifestUrl = '/api/manifest',
      String serverUrl = 'https://example.invalid',
      void Function(Uri)? onRequest,
    }) {
      final client = MockClient((request) async {
        onRequest?.call(request.url);
        if (request.url.path.endsWith('/api/version')) {
          return http.Response(
            jsonEncode({
              'latestVersion': served.version,
              'latestBuildNumber': served.buildNumber,
              'channels': {
                'stable': {
                  'version': channelVersion ?? served.version,
                  'manifestUrl': manifestUrl,
                },
              },
            }),
            200,
          );
        }
        final expectedManifestPath = Uri.parse(manifestUrl).path;
        if (request.url.path.endsWith(expectedManifestPath)) {
          return http.Response(jsonEncode(served.toJson()), 200);
        }
        return http.Response('not found', 404);
      });

      final service = UpdateService(
        currentVersion: currentVersion,
        currentBuildNumber: currentBuildNumber,
        httpClient: client,
        currentPlatform: 'windows',
        currentArch: 'x64',
      );
      service.configure(serverUrl: serverUrl);
      return service;
    }

    test(
      'offers when version equals current but buildNumber is greater',
      () async {
        final service = serviceFor(
          manifest(version: '2.0.0', buildNumber: 5),
          currentVersion: '2.0.0',
          currentBuildNumber: 4,
        );
        final result = await service.checkForUpdates();
        expect(result.hasUpdate, isTrue);
        expect(result.availableVersion, '2.0.0');
      },
    );

    test(
      'does NOT offer when version and buildNumber both equal current',
      () async {
        final service = serviceFor(
          manifest(version: '2.0.0', buildNumber: 4),
          currentVersion: '2.0.0',
          currentBuildNumber: 4,
        );
        final result = await service.checkForUpdates();
        expect(result.hasUpdate, isFalse);
      },
    );

    test('still offers a strictly newer semver (unchanged behavior)', () async {
      final service = serviceFor(
        manifest(version: '2.1.0', buildNumber: 1),
        currentVersion: '2.0.0',
        currentBuildNumber: 99,
      );
      final result = await service.checkForUpdates();
      expect(result.hasUpdate, isTrue);
      expect(result.availableVersion, '2.1.0');
    });

    test('rejects a manifest for another operating system', () async {
      final service = serviceFor(
        manifest(platform: 'linux'),
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
      );

      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            allOf(contains('linux/x64'), contains('windows/x64')),
          ),
        ),
      );
    });

    test('rejects a manifest for another CPU architecture', () async {
      final service = serviceFor(
        manifest(arch: 'arm64'),
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
      );

      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            allOf(contains('windows/arm64'), contains('windows/x64')),
          ),
        ),
      );
    });

    test('rejects a channel index and manifest version mismatch', () async {
      final service = serviceFor(
        manifest(version: '2.1.0'),
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        channelVersion: '2.2.0',
      );

      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            allOf(contains('2.2.0'), contains('2.1.0')),
          ),
        ),
      );
    });

    test(
      'resolves a relative manifest URL from the server directory',
      () async {
        final requested = <Uri>[];
        final service = serviceFor(
          manifest(),
          currentVersion: '2.0.0',
          currentBuildNumber: 1,
          manifestUrl: 'manifests/stable.json',
          serverUrl: 'https://example.invalid/releases',
          onRequest: requested.add,
        );

        final result = await service.checkForUpdates();

        expect(result.hasUpdate, isTrue);
        expect(
          requested,
          contains(
            Uri.parse('https://example.invalid/releases/manifests/stable.json'),
          ),
        );
      },
    );

    test('wraps a non-object version response as an update error', () async {
      final service = UpdateService(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        currentPlatform: 'windows',
        currentArch: 'x64',
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      )..configure(serverUrl: 'https://example.invalid');

      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            contains('Invalid response format'),
          ),
        ),
      );
    });
  });
}
