import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/update_manifest.dart';

/// Discovers releases from the GitHub Releases API.
///
/// The rest of this package was built against a Nightshade update server
/// (`/api/version` -> channel -> manifest URL). Nothing ever hosted one, so
/// every shipped build had an inert updater while the releases that CI
/// publishes — signed manifest included — sat on GitHub unread. This source
/// replaces only the discovery hop: it finds the manifest asset attached to a
/// release and hands the parsed manifest back. Signature verification, hash
/// checks, staging and apply are unchanged, so a release this source finds is
/// trusted no further than one a server advertised.
///
/// The release JSON itself is untrusted input. It decides *which* manifest to
/// read and what to show in the release-notes pane; it can never decide that
/// an unsigned manifest is acceptable.
class GithubReleaseSource {
  /// `owner/repo` this source reads releases from.
  final String owner;
  final String repo;

  final http.Client _httpClient;
  final Duration _timeout;
  final String _apiBase;

  GithubReleaseSource({
    required this.owner,
    required this.repo,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
    String apiBase = 'https://api.github.com',
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _apiBase = apiBase.endsWith('/')
           ? apiBase.substring(0, apiBase.length - 1)
           : apiBase;

  /// Human-facing releases page, used when the app can only point somewhere.
  String get releasesPageUrl => 'https://github.com/$owner/$repo/releases';

  /// The newest release on [channel], or null when there is none.
  ///
  /// A repository with no matching release is not an error an operator can
  /// act on. [GithubReleaseException] is thrown when the API answers but the
  /// answer cannot be used. Reading the manifest off the release is a
  /// separate step — see [fetchManifest].
  ///
  /// `stable` reads `/releases/latest`, which GitHub defines as the newest
  /// non-prerelease, non-draft release. Any other channel lists releases and
  /// takes the newest whose tag carries that channel as a prerelease tag
  /// (`v7.2.0-beta.1` for `beta`), so a beta tester is never handed a stable
  /// build they already have, nor a draft nobody published.
  Future<GithubRelease?> fetchLatestRelease({String channel = 'stable'}) =>
      channel == 'stable'
      ? _fetchLatestStable()
      : _fetchLatestPrerelease(channel);

  Future<GithubRelease?> _fetchLatestStable() async {
    final response = await _get('$_apiBase/repos/$owner/$repo/releases/latest');
    // 404 is the documented answer for "this repository has published no
    // release", not a failure to report.
    if (response.statusCode == 404) return null;
    final decoded = _decodeObject(response);
    return GithubRelease.fromJson(decoded);
  }

  Future<GithubRelease?> _fetchLatestPrerelease(String channel) async {
    final response = await _get(
      '$_apiBase/repos/$owner/$repo/releases?per_page=30',
    );
    if (response.statusCode == 404) return null;
    final body = jsonDecode(_bodyOrThrow(response));
    if (body is! List) {
      throw GithubReleaseException(
        'Expected a list of releases from GitHub, got ${body.runtimeType}.',
      );
    }
    // The list arrives newest-first by creation date. Take the first entry
    // that belongs to this channel and was actually published.
    for (final entry in body) {
      if (entry is! Map<String, dynamic>) continue;
      final release = GithubRelease.fromJson(entry);
      if (release.isDraft) continue;
      if (release.matchesChannel(channel)) return release;
    }
    return null;
  }

  /// Download and parse the manifest asset [release] carries for
  /// [platform]/[arch].
  ///
  /// Throws when the release has no manifest at all for this host: that is a
  /// release that cannot be installed here, and saying so beats silently
  /// reporting "up to date" on a machine whose platform was dropped from a
  /// build.
  Future<ResolvedManifest> fetchManifest(
    GithubRelease release, {
    required String platform,
    required String arch,
  }) async {
    final asset = selectManifestAsset(
      release.assets,
      platform: platform,
      arch: arch,
    );
    if (asset == null) {
      throw GithubReleaseException(
        'Release ${release.tagName} publishes no update manifest for '
        '$platform/$arch. Assets: '
        '${release.assets.map((a) => a.name).join(', ')}',
      );
    }

    final response = await _get(asset.downloadUrl);
    final decoded = _decodeObject(response);
    try {
      return ResolvedManifest(
        manifest: UpdateManifest.fromJson(decoded),
        // Releases published before per-target naming carry one manifest for
        // whichever platform built it. Matching that is not evidence the
        // release has a build for this host, so the caller has to treat a
        // mismatch as "nothing for you here" rather than as a fault.
        isGenericFallback: asset.name.toLowerCase() == 'manifest.json',
      );
    } on FormatException catch (e) {
      throw GithubReleaseException(
        'Manifest ${asset.name} on release ${release.tagName} is not a '
        'readable update manifest: ${e.message}',
      );
    } on TypeError catch (e) {
      throw GithubReleaseException(
        'Manifest ${asset.name} on release ${release.tagName} is missing a '
        'required field: $e',
      );
    }
  }

  Future<http.Response> _get(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      throw GithubReleaseException(
        'Refusing to read a release over a non-https URL: "$url".',
      );
    }
    try {
      return await _httpClient
          .get(
            uri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(
            _timeout,
            onTimeout: () => throw GithubReleaseException(
              'GitHub did not respond within ${_timeout.inSeconds}s ($uri).',
            ),
          );
    } on SocketException catch (e) {
      throw GithubReleaseException('Network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw GithubReleaseException('Network error: ${e.message}');
    }
  }

  String _bodyOrThrow(http.Response response) {
    if (response.statusCode == 200) return response.body;
    // Rate limiting is the one failure an operator hits routinely on an
    // unauthenticated API, so name it instead of showing a bare 403.
    if (response.statusCode == 403 &&
        response.headers['x-ratelimit-remaining'] == '0') {
      throw GithubReleaseException(
        'GitHub rate limit reached for this network. Update checks resume '
        'once it resets.',
      );
    }
    throw GithubReleaseException(
      'GitHub answered ${response.statusCode} for the release check.',
    );
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final body = _bodyOrThrow(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw GithubReleaseException(
        'Expected a JSON object from GitHub, got ${decoded.runtimeType}.',
      );
    }
    return decoded;
  }
}

/// Pick the manifest asset that describes a build for [platform]/[arch].
///
/// Names are matched most-specific first, so a release may carry manifests for
/// several targets at once without an arm64 host ever matching an x64 build.
/// A bare `manifest.json` is accepted last for releases published before the
/// per-target naming existed; the manifest's own `platform`/`arch` fields are
/// checked downstream, so an old single-target manifest is rejected there
/// rather than installed on the wrong machine.
GithubReleaseAsset? selectManifestAsset(
  List<GithubReleaseAsset> assets, {
  required String platform,
  required String arch,
}) {
  final preferred = <String>[
    'manifest-$platform-$arch.json',
    'manifest-$platform.json',
    'manifest.json',
  ];
  for (final name in preferred) {
    for (final asset in assets) {
      if (asset.name.toLowerCase() == name.toLowerCase()) return asset;
    }
  }
  return null;
}

/// A manifest read off a release, plus how it was chosen.
class ResolvedManifest {
  final UpdateManifest manifest;

  /// True when this came from a bare `manifest.json` rather than a manifest
  /// named for this host's platform and architecture.
  final bool isGenericFallback;

  const ResolvedManifest({
    required this.manifest,
    required this.isGenericFallback,
  });
}

/// One published GitHub release.
class GithubRelease {
  final String tagName;

  /// Release title. Falls back to the tag when GitHub has no name for it.
  final String name;

  /// Release body as authored, in markdown.
  final String? body;

  final DateTime? publishedAt;
  final bool isPrerelease;
  final bool isDraft;
  final String htmlUrl;
  final List<GithubReleaseAsset> assets;

  const GithubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.isPrerelease,
    required this.isDraft,
    required this.htmlUrl,
    required this.assets,
  });

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    if (tag is! String || tag.trim().isEmpty) {
      throw GithubReleaseException('Release carries no version tag.');
    }
    final rawAssets = json['assets'];
    final assets = <GithubReleaseAsset>[];
    if (rawAssets is List) {
      for (final entry in rawAssets) {
        if (entry is! Map<String, dynamic>) continue;
        final asset = GithubReleaseAsset.tryFromJson(entry);
        if (asset != null) assets.add(asset);
      }
    }
    final published = json['published_at'];
    return GithubRelease(
      tagName: tag.trim(),
      name: switch (json['name']) {
        final String n when n.trim().isNotEmpty => n.trim(),
        _ => tag.trim(),
      },
      body: switch (json['body']) {
        final String b when b.trim().isNotEmpty => b,
        _ => null,
      },
      publishedAt: published is String
          ? DateTime.tryParse(published)?.toUtc()
          : null,
      isPrerelease: json['prerelease'] == true,
      isDraft: json['draft'] == true,
      htmlUrl: switch (json['html_url']) {
        final String u when u.trim().isNotEmpty => u.trim(),
        _ => '',
      },
      assets: assets,
    );
  }

  /// Version carried by the tag, with any leading `v` removed.
  /// `v7.2.0` -> `7.2.0`.
  String get version => stripReleaseTagPrefix(tagName);

  /// Whether this release belongs to [channel].
  ///
  /// `stable` means no prerelease tag at all. Any other channel matches when
  /// the tag's prerelease identifiers lead with that channel name, so
  /// `v7.2.0-beta.1` is on `beta` and `v7.2.0-rc.1` is not.
  bool matchesChannel(String channel) {
    final dash = version.indexOf('-');
    if (channel == 'stable') return dash < 0 && !isPrerelease;
    if (dash < 0) return false;
    final identifiers = version.substring(dash + 1).split('+').first.split('.');
    return identifiers.isNotEmpty &&
        identifiers.first.toLowerCase() == channel.toLowerCase();
  }
}

/// One file attached to a release.
class GithubReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;

  const GithubReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  /// Returns null for an asset entry missing a name or URL rather than
  /// throwing: one malformed entry should not hide a release whose other
  /// assets are fine.
  static GithubReleaseAsset? tryFromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || name.trim().isEmpty) return null;
    if (url is! String || url.trim().isEmpty) return null;
    final size = json['size'];
    return GithubReleaseAsset(
      name: name.trim(),
      downloadUrl: url.trim(),
      size: size is int ? size : 0,
    );
  }
}

/// `v7.2.0` / ` 7.2.0 ` -> `7.2.0`.
String stripReleaseTagPrefix(String raw) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
    return trimmed.substring(1);
  }
  return trimmed;
}

/// Tidy a GitHub release body for display in the update pane.
///
/// Two things in an auto-generated body read badly in a small in-app panel:
/// full pull-request URLs, which wrap and say nothing a number would not, and
/// the trailing "Full Changelog" line, which is a link to a page the operator
/// cannot open from there. Everything else is left exactly as authored —
/// release notes are the one place the app quotes a human.
String? tidyReleaseNotes(String? body) {
  if (body == null) return null;
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  final cleaned = trimmed
      .replaceAllMapped(
        RegExp(r'https://github\.com/[\w.-]+/[\w.-]+/pull/(\d+)'),
        (match) => '#${match.group(1)}',
      )
      .replaceAll(RegExp(r'\*\*Full Changelog\*\*.*$', multiLine: true), '')
      .trimRight();
  return cleaned.isEmpty ? null : cleaned;
}

/// Raised when GitHub answers but the answer cannot be used.
class GithubReleaseException implements Exception {
  final String message;

  GithubReleaseException(this.message);

  @override
  String toString() => 'GithubReleaseException: $message';
}
