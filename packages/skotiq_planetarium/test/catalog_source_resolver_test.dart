// Unit tests for the catalog download-source resolution introduced to make the
// bulk catalogs (HYG, OpenNGC) fetch from immutable GitHub release assets FIRST
// with a SHA-256 integrity gate, then fall back to the upstream third-party
// host. These exercise the pure resolver + hash helpers only — no network.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  group('catalogDownloadCandidates ordering', () {
    const base = 'https://example.com/releases/catalogs-v1';

    test('GitHub release asset is first, upstream fallback is second', () {
      final candidates = catalogDownloadCandidates(
        githubAssetName: 'thing.csv.gz',
        upstreamUrl: 'https://upstream.example/thing.csv.gz',
        baseUrl: base,
      );
      expect(candidates, [
        '$base/thing.csv.gz',
        'https://upstream.example/thing.csv.gz',
      ]);
    });

    test('trailing slash on base is normalized (no double slash)', () {
      final candidates = catalogDownloadCandidates(
        githubAssetName: 'thing.csv',
        upstreamUrl: 'https://upstream.example/thing.csv',
        baseUrl: '$base/',
      );
      expect(candidates.first, '$base/thing.csv');
    });

    test('empty asset name collapses to just the upstream fallback', () {
      final candidates = catalogDownloadCandidates(
        githubAssetName: '',
        upstreamUrl: 'https://upstream.example/dynamic',
        baseUrl: base,
      );
      expect(candidates, ['https://upstream.example/dynamic']);
    });

    test('empty base collapses to just the upstream fallback', () {
      final candidates = catalogDownloadCandidates(
        githubAssetName: 'thing.csv',
        upstreamUrl: 'https://upstream.example/thing.csv',
        baseUrl: '',
      );
      expect(candidates, ['https://upstream.example/thing.csv']);
    });

    test('duplicate primary/upstream is de-duped', () {
      const same = '$base/thing.csv';
      final candidates = catalogDownloadCandidates(
        githubAssetName: 'thing.csv',
        upstreamUrl: same,
        baseUrl: base,
      );
      expect(candidates, [same]);
    });

    test('a source with neither asset nor upstream yields no candidates', () {
      expect(
        catalogDownloadCandidates(
          githubAssetName: '',
          upstreamUrl: '',
          baseUrl: base,
        ),
        isEmpty,
      );
    });
  });

  group('resolveCatalogDownloadCandidates for the real catalog sources', () {
    test('HYG: GitHub v44 asset primary, Codeberg /media/ v44 fallback', () {
      final candidates = resolveCatalogDownloadCandidates(
        hygStarCatalog,
        baseUrl: kCatalogReleaseBaseUrl,
      );
      expect(candidates.length, 2);
      // Primary is the immutable release asset.
      expect(candidates.first, '$kCatalogReleaseBaseUrl/hyg_v44.csv.gz');
      // Fallback is the v44 /media/ (LFS content) URL, NOT /raw/.
      expect(candidates[1], contains('/media/'));
      expect(candidates[1], contains('hyg_v44.csv.gz'));
      expect(candidates[1], isNot(contains('/raw/')));
      // The dead v42 reference must be gone from every candidate.
      for (final url in candidates) {
        expect(url, isNot(contains('v42')));
      }
    });

    test('OpenNGC: GitHub asset primary, raw.githubusercontent fallback', () {
      final candidates = resolveCatalogDownloadCandidates(
        openNgcCatalog,
        baseUrl: kCatalogReleaseBaseUrl,
      );
      expect(candidates.length, 2);
      expect(candidates.first, '$kCatalogReleaseBaseUrl/NGC.csv');
      expect(candidates[1], contains('raw.githubusercontent.com'));
    });

    test('a configured override base repoints the primary candidate', () {
      const override = 'https://mirror.internal/catalogs';
      final candidates = resolveCatalogDownloadCandidates(
        hygStarCatalog,
        baseUrl: override,
      );
      expect(candidates.first, '$override/hyg_v44.csv.gz');
      // Upstream fallback is unaffected by the override.
      expect(candidates.last, hygStarCatalog.downloadUrl);
    });
  });

  group('SHA-256 verification of the as-downloaded bytes', () {
    final bytes = utf8.encode('id,ra,dec\n1,2.5,89.2\n');
    late final String goodHash = sha256.convert(bytes).toString();

    test('matching hash accepts the candidate', () {
      expect(catalogBytesMatchSha256(goodHash, bytes), isTrue);
      expect(catalogSha256Matches(goodHash, goodHash), isTrue);
    });

    test('a wrong hash rejects the candidate', () {
      const wrong =
          '0000000000000000000000000000000000000000000000000000000000000000';
      expect(catalogBytesMatchSha256(wrong, bytes), isFalse);
      expect(catalogSha256Matches(wrong, goodHash), isFalse);
    });

    test('the real HYG hash rejects unrelated bytes', () {
      // Guards against a wrong-payload candidate (or a hash-of-decompressed vs
      // hash-of-compressed mixup) silently installing.
      expect(catalogBytesMatchSha256(hygStarCatalog.sha256, bytes), isFalse);
    });

    test('hash comparison is case-insensitive', () {
      expect(catalogSha256Matches(goodHash.toUpperCase(), goodHash), isTrue);
    });

    test('an empty expected hash always matches (no canonical hash, e.g. '
        'GLADE+)', () {
      expect(catalogBytesMatchSha256('', bytes), isTrue);
      expect(catalogSha256Matches('', 'anything'), isTrue);
      expect(gladePlusCatalog.sha256, isEmpty);
    });
  });

  group('catalog source constants', () {
    test('HYG carries the exact published as-downloaded (gzipped) hash', () {
      expect(
        hygStarCatalog.sha256,
        '00b349893b9a53106dd488d8371e8d2fa586043e500bb3cdb8bff3931682197d',
      );
      expect(hygStarCatalog.isGzipped, isTrue);
      expect(hygStarCatalog.githubAssetName, 'hyg_v44.csv.gz');
    });

    test('OpenNGC carries the exact published hash and is not gzipped', () {
      expect(
        openNgcCatalog.sha256,
        '840fe0c9ee1332e551b2e722a0e92726cd7b157914a3d2177602832aadd3aa9e',
      );
      expect(openNgcCatalog.isGzipped, isFalse);
      expect(openNgcCatalog.githubAssetName, 'NGC.csv');
    });
  });
}
