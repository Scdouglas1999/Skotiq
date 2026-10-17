// Discovery via the GitHub Releases API. This is the only source a shipped
// build has, so the failure modes here are the ones that decide whether OTA
// works at all: picking the wrong asset installs another machine's build, and
// treating a rate-limit or a draft as "up to date" silently strands everyone
// on an old version.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/github_release_source.dart';
import 'package:skotiq_updater/src/services/update_service.dart';

UpdateManifest manifest({
  String version = '7.2.0',
  int buildNumber = 42,
  String platform = 'linux',
  String arch = 'x64',
  String? minVersion,
  String? releaseNotes,
}) => UpdateManifest(
  version: version,
  buildNumber: buildNumber,
  releaseDate: DateTime.utc(2026, 9, 20),
  platform: platform,
  arch: arch,
  minVersion: minVersion,
  files: const {'app': UpdateFileInfo(path: 'app', size: 4, sha256: 'abc')},
  totalSize: 4,
  compressedSize: 4,
  packageSha256: 'abc',
  downloadUrl: 'https://example.invalid/pkg.zip',
  releaseNotes: releaseNotes,
);

Map<String, dynamic> releaseJson({
  String tag = 'v7.2.0',
  String? body,
  bool prerelease = false,
  bool draft = false,
  List<String> assetNames = const ['manifest-linux-x64.json'],
}) => {
  'tag_name': tag,
  'name': tag,
  'body': body,
  'published_at': '2026-09-20T12:00:00Z',
  'prerelease': prerelease,
  'draft': draft,
  'html_url': 'https://github.com/o/r/releases/tag/$tag',
  'assets': [
    for (final name in assetNames)
      {
        'name': name,
        'browser_download_url': 'https://example.invalid/$name',
        'size': 10,
      },
  ],
};

void main() {
  group('asset selection', () {
    GithubReleaseAsset asset(String name) => GithubReleaseAsset(
      name: name,
      downloadUrl: 'https://example.invalid/$name',
      size: 1,
    );

    test('prefers the exact platform+arch manifest', () {
      final chosen = selectManifestAsset(
        [
          asset('manifest-windows-x64.json'),
          asset('manifest-linux-x64.json'),
          asset('manifest-android-arm64.json'),
        ],
        platform: 'linux',
        arch: 'x64',
      );
      expect(chosen?.name, 'manifest-linux-x64.json');
    });

    test('an arm64 host is never handed the x64 manifest', () {
      // The whole point of per-target manifests: before them, a release
      // carrying one manifest.json meant every device got the same package.
      final chosen = selectManifestAsset(
        [asset('manifest-android-x64.json')],
        platform: 'android',
        arch: 'arm64',
      );
      expect(chosen, isNull);
    });

    test('falls back to a bare manifest.json for older releases', () {
      final chosen = selectManifestAsset(
        [asset('manifest.json')],
        platform: 'windows',
        arch: 'x64',
      );
      expect(chosen?.name, 'manifest.json');
    });

    test('returns null when no manifest is attached at all', () {
      final chosen = selectManifestAsset(
        [asset('skotiq-7.2.0-linux-x64.zip'), asset('LICENSE.txt')],
        platform: 'linux',
        arch: 'x64',
      );
      expect(chosen, isNull);
    });
  });

  group('release parsing', () {
    test('strips the v prefix from the tag', () {
      expect(
        GithubRelease.fromJson(releaseJson(tag: 'v7.2.0')).version,
        '7.2.0',
      );
      expect(
        GithubRelease.fromJson(releaseJson(tag: '7.2.0')).version,
        '7.2.0',
      );
    });

    test('a release with no tag is rejected rather than guessed at', () {
      expect(
        () => GithubRelease.fromJson({'tag_name': '  ', 'assets': []}),
        throwsA(isA<GithubReleaseException>()),
      );
    });

    test('channel matching separates stable from prereleases', () {
      final stable = GithubRelease.fromJson(releaseJson(tag: 'v7.2.0'));
      final beta = GithubRelease.fromJson(
        releaseJson(tag: 'v7.3.0-beta.1', prerelease: true),
      );
      final rc = GithubRelease.fromJson(
        releaseJson(tag: 'v7.3.0-rc.1', prerelease: true),
      );

      expect(stable.matchesChannel('stable'), isTrue);
      expect(stable.matchesChannel('beta'), isFalse);
      expect(beta.matchesChannel('beta'), isTrue);
      expect(beta.matchesChannel('stable'), isFalse);
      // A beta tester must not be handed an rc build.
      expect(rc.matchesChannel('beta'), isFalse);
      expect(rc.matchesChannel('rc'), isTrue);
    });

    test('a malformed asset entry does not hide the rest of the release', () {
      final release = GithubRelease.fromJson({
        'tag_name': 'v7.2.0',
        'assets': [
          {'name': 'broken-no-url'},
          {
            'name': 'manifest-linux-x64.json',
            'browser_download_url': 'https://example.invalid/m.json',
            'size': 5,
          },
        ],
      });
      expect(release.assets, hasLength(1));
      expect(release.assets.single.name, 'manifest-linux-x64.json');
    });
  });

  group('release notes', () {
    test('pull request URLs collapse to numbers', () {
      final tidied = tidyReleaseNotes(
        'Fixed guiding https://github.com/Scdouglas1999/Skotiq/pull/412',
      );
      expect(tidied, 'Fixed guiding #412');
    });

    test('the trailing Full Changelog link is dropped', () {
      final tidied = tidyReleaseNotes(
        'Real notes here\n\n**Full Changelog**: https://github.com/o/r/compare/v1...v2',
      );
      expect(tidied, 'Real notes here');
    });

    test('an empty or absent body reads as no notes', () {
      expect(tidyReleaseNotes(null), isNull);
      expect(tidyReleaseNotes('   '), isNull);
    });
  });

  group('fetching', () {
    GithubReleaseSource sourceWith(
      Future<http.Response> Function(http.Request) handler,
    ) => GithubReleaseSource(
      owner: 'o',
      repo: 'r',
      httpClient: MockClient(handler),
    );

    test('a repository with no releases reads as nothing to offer', () async {
      final source = sourceWith((_) async => http.Response('{}', 404));
      expect(await source.fetchLatestRelease(), isNull);
    });

    test('rate limiting is reported as rate limiting', () async {
      // Otherwise this shows up as a bare 403 on an unauthenticated network,
      // which reads like a permissions bug rather than "wait a while".
      final source = sourceWith(
        (_) async => http.Response(
          'limit',
          403,
          headers: {'x-ratelimit-remaining': '0'},
        ),
      );
      await expectLater(
        source.fetchLatestRelease(),
        throwsA(
          isA<GithubReleaseException>().having(
            (e) => e.message,
            'message',
            contains('rate limit'),
          ),
        ),
      );
    });

    test('a beta channel skips stable and draft releases', () async {
      final source = sourceWith((request) async {
        expect(request.url.path, '/repos/o/r/releases');
        return http.Response(
          jsonEncode([
            releaseJson(tag: 'v7.3.0-beta.2', draft: true, prerelease: true),
            releaseJson(tag: 'v7.2.0'),
            releaseJson(tag: 'v7.3.0-beta.1', prerelease: true),
          ]),
          200,
        );
      });

      final release = await source.fetchLatestRelease(channel: 'beta');
      expect(release?.tagName, 'v7.3.0-beta.1');
    });

    test('a release with no manifest for this host says so', () async {
      final source = sourceWith(
        (_) async => http.Response(
          jsonEncode(releaseJson(assetNames: ['manifest-windows-x64.json'])),
          200,
        ),
      );
      final release = await source.fetchLatestRelease();
      await expectLater(
        source.fetchManifest(release!, platform: 'linux', arch: 'x64'),
        throwsA(
          isA<GithubReleaseException>().having(
            (e) => e.message,
            'message',
            contains('no update manifest for linux/x64'),
          ),
        ),
      );
    });
  });

  group('UpdateService against a GitHub source', () {
    UpdateService serviceWith({
      required UpdateManifest served,
      required String currentVersion,
      required int currentBuildNumber,
      String tag = 'v7.2.0',
      String? body,
      String platform = 'linux',
      String arch = 'x64',
    }) {
      final client = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode(
              releaseJson(
                tag: tag,
                body: body,
                assetNames: ['manifest-$platform-$arch.json'],
              ),
            ),
            200,
          );
        }
        return http.Response(jsonEncode(served.toJson()), 200);
      });

      final service = UpdateService(
        currentVersion: currentVersion,
        currentBuildNumber: currentBuildNumber,
        httpClient: client,
        currentPlatform: platform,
        currentArch: arch,
      );
      service.configureGithubSource(
        owner: 'o',
        repo: 'r',
        source: GithubReleaseSource(owner: 'o', repo: 'r', httpClient: client),
      );
      return service;
    }

    test('offers a newer release found on GitHub', () async {
      final service = serviceWith(
        served: manifest(version: '7.2.0', buildNumber: 42),
        currentVersion: '7.1.0',
        currentBuildNumber: 40,
      );
      final result = await service.checkForUpdates();
      expect(result.hasUpdate, isTrue);
      expect(result.availableVersion, '7.2.0');
      expect(result.releasePageUrl, contains('releases/tag/v7.2.0'));
    });

    test('does not offer the build already running', () async {
      final service = serviceWith(
        served: manifest(version: '7.2.0', buildNumber: 42),
        currentVersion: '7.2.0',
        currentBuildNumber: 42,
      );
      expect((await service.checkForUpdates()).hasUpdate, isFalse);
    });

    test('refuses when the tag and the manifest disagree', () async {
      // Assets on one release built from two different commits: installing
      // the package the manifest names would put an unexpected build on the
      // machine, so neither side is trusted over the other.
      final service = serviceWith(
        served: manifest(version: '7.2.0'),
        currentVersion: '7.1.0',
        currentBuildNumber: 1,
        tag: 'v7.3.0',
      );
      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('Update metadata mismatch'),
          ),
        ),
      );
    });

    test('refuses a manifest built for another architecture', () async {
      final service = serviceWith(
        served: manifest(version: '7.2.0', platform: 'linux', arch: 'arm64'),
        currentVersion: '7.1.0',
        currentBuildNumber: 1,
        platform: 'linux',
        arch: 'x64',
      );
      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('targets linux/arm64'),
          ),
        ),
      );
    });

    test('the GitHub body is shown, not the signed manifest notes', () async {
      // releaseNotes is inside the signed canonical payload, so the richer
      // GitHub body has to travel beside the manifest rather than replace
      // the field — doing that would invalidate every signature.
      final served = manifest(version: '7.2.0', releaseNotes: 'terse');
      final service = serviceWith(
        served: served,
        currentVersion: '7.1.0',
        currentBuildNumber: 1,
        body: 'What actually changed\n\n**Full Changelog**: https://x/y',
      );
      final result = await service.checkForUpdates();
      expect(result.releaseNotes, 'What actually changed');
      expect(result.manifest!.releaseNotes, 'terse');
    });

    test(
      'a legacy single-platform release is not an error on other hosts',
      () async {
        // Reproduces what the published v7.1.0 release does: one bare
        // manifest.json describing the Windows build, alongside Linux and
        // Android packages that have no manifest of their own. Before this,
        // every Linux and Android install reported "Could not check for
        // updates: ... targets windows/x64" on every single check.
        final client = MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              jsonEncode(releaseJson(assetNames: ['manifest.json'])),
              200,
            );
          }
          return http.Response(
            jsonEncode(
              manifest(
                version: '7.2.0',
                platform: 'windows',
                arch: 'x64',
              ).toJson(),
            ),
            200,
          );
        });

        final service =
            UpdateService(
              currentVersion: '7.1.0',
              currentBuildNumber: 28,
              httpClient: client,
              currentPlatform: 'linux',
              currentArch: 'x64',
            )..configureGithubSource(
              owner: 'o',
              repo: 'r',
              source: GithubReleaseSource(
                owner: 'o',
                repo: 'r',
                httpClient: client,
              ),
            );

        final result = await service.checkForUpdates();
        expect(result.hasUpdate, isFalse);
        // ...but it must not be reported as plain currency either.
        expect(
          result.unavailableReason,
          contains('no update that this linux/x64 build can install'),
        );
      },
    );

    test('a per-target manifest that lies about its target is loud', () async {
      // manifest-linux-x64.json describing a Windows build is a packaging
      // fault, not an ordinary state, so it stays an error.
      final client = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode(releaseJson(assetNames: ['manifest-linux-x64.json'])),
            200,
          );
        }
        return http.Response(
          jsonEncode(
            manifest(
              version: '7.2.0',
              platform: 'windows',
              arch: 'x64',
            ).toJson(),
          ),
          200,
        );
      });

      final service =
          UpdateService(
            currentVersion: '7.1.0',
            currentBuildNumber: 28,
            httpClient: client,
            currentPlatform: 'linux',
            currentArch: 'x64',
          )..configureGithubSource(
            owner: 'o',
            repo: 'r',
            source: GithubReleaseSource(
              owner: 'o',
              repo: 'r',
              httpClient: client,
            ),
          );

      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('targets windows/x64'),
          ),
        ),
      );
    });

    test('a build below minVersion is routed to a manual reinstall', () async {
      final service = serviceWith(
        served: manifest(version: '7.2.0', minVersion: '7.0.0'),
        currentVersion: '6.5.0',
        currentBuildNumber: 1,
      );
      final result = await service.checkForUpdates();
      expect(result.hasUpdate, isTrue);
      expect(result.requiresManualUpgrade, isTrue);
    });
  });
}
