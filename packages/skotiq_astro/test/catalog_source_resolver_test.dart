// Unit tests for the catalog download-source resolution introduced to make the
// bulk catalogs (HYG, OpenNGC) fetch from immutable GitHub release assets FIRST
// with a SHA-256 integrity gate, then fall back to the upstream third-party
// host. These exercise the pure resolver + hash helpers only — no network.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  group('download candidates', () {
    test('HYG: GitHub v44 asset primary, Codeberg /media/ v44 fallback', () {
      final candidates = SkyCatalog.stars.downloadCandidates(
        baseUrl: kCatalogReleaseBaseUrl,
      );
      expect(candidates.length, 2);
      expect(candidates.first, '$kCatalogReleaseBaseUrl/hyg_v44.csv.gz');
      // /raw/ returns a 133-byte LFS pointer, not the file.
      expect(candidates[1], contains('/media/'));
      expect(candidates[1], contains('hyg_v44.csv.gz'));
      expect(candidates[1], isNot(contains('/raw/')));
      for (final url in candidates) {
        expect(url, isNot(contains('v42')));
      }
    });

    test('OpenNGC: GitHub asset primary, raw.githubusercontent fallback', () {
      final candidates = SkyCatalog.dso.downloadCandidates(
        baseUrl: kCatalogReleaseBaseUrl,
      );
      expect(candidates.length, 2);
      expect(candidates.first, '$kCatalogReleaseBaseUrl/NGC.csv');
      expect(candidates[1], contains('raw.githubusercontent.com'));
    });

    test('a configured override base repoints the primary candidate', () {
      const override = 'https://mirror.example/catalogs';
      final candidates = SkyCatalog.stars.downloadCandidates(
        baseUrl: '$override/',
      );
      // A trailing slash on the base must not produce a double slash.
      expect(candidates.first, '$override/hyg_v44.csv.gz');
      expect(candidates.last, SkyCatalog.stars.upstreamUrl);
    });

    test('an empty base collapses to just the upstream fallback', () {
      expect(SkyCatalog.dso.downloadCandidates(baseUrl: ''), [
        SkyCatalog.dso.upstreamUrl,
      ]);
    });

    test('GLADE+ has no release asset: one TAP query per tier', () {
      for (final tier in AnnotationPackage.values) {
        expect(
          SkyCatalog.annotation.downloadCandidates(
            baseUrl: kCatalogReleaseBaseUrl,
            tier: tier,
          ),
          [gladePlusUrl(tier)],
        );
      }
      expect(
        gladePlusUrl(AnnotationPackage.complete),
        isNot(contains('WHERE')),
      );
      expect(
        Uri.decodeComponent(gladePlusUrl(AnnotationPackage.essential)),
        contains('"Bmag" <= 14.0'),
      );
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
      expect(catalogBytesMatchSha256(SkyCatalog.stars.sha256, bytes), isFalse);
    });

    test('hash comparison is case-insensitive', () {
      expect(catalogSha256Matches(goodHash.toUpperCase(), goodHash), isTrue);
    });

    test('an empty expected hash always matches (no canonical hash, e.g. '
        'GLADE+)', () {
      expect(catalogBytesMatchSha256('', bytes), isTrue);
      expect(catalogSha256Matches('', 'anything'), isTrue);
      expect(SkyCatalog.annotation.sha256, isEmpty);
    });
  });

  group('catalog source constants', () {
    test('HYG carries the exact published as-downloaded (gzipped) hash', () {
      expect(
        SkyCatalog.stars.sha256,
        '00b349893b9a53106dd488d8371e8d2fa586043e500bb3cdb8bff3931682197d',
      );
      expect(SkyCatalog.stars.githubAssetName, 'hyg_v44.csv.gz');
    });

    test('OpenNGC carries the exact published hash and is not gzipped', () {
      expect(
        SkyCatalog.dso.sha256,
        '840fe0c9ee1332e551b2e722a0e92726cd7b157914a3d2177602832aadd3aa9e',
      );
      expect(SkyCatalog.dso.githubAssetName, 'NGC.csv');
    });
  });
}
