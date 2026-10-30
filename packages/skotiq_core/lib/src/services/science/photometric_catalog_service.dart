import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_planetarium/skotiq_planetarium.dart' show CatalogManager;
import 'package:path/path.dart' as p;

import '../../models/science/science_models.dart';
import '../../providers/database_provider.dart';
import '../logging_service.dart';
import '../../utils/skotiq_data_directory.dart';
import 'photometric_bands.dart';

/// One catalog star usable for photometric work: position, Johnson V, and
/// (when the catalog provides them) a B-V color index and Sloan r'.
class PhotometricCatalogStar {
  final double raDegrees;
  final double decDegrees;
  final double magV;
  final double? colorIndexBv;

  /// Sloan r' magnitude (APASS), when known.
  final double? magR;

  const PhotometricCatalogStar({
    required this.raDegrees,
    required this.decDegrees,
    required this.magV,
    this.colorIndexBv,
    this.magR,
  });

  /// Johnson B, when the B-V color is known.
  double? get magB => colorIndexBv == null ? null : magV + colorIndexBv!;

  /// This star's magnitude in [band], or null when the catalog lacks it.
  double? magIn(PhotometricBand band) => switch (band) {
    PhotometricBand.johnsonV => magV,
    PhotometricBand.johnsonB => magB,
    PhotometricBand.sloanR => magR,
  };

  Map<String, dynamic> toJson() => {
    'ra': raDegrees,
    'dec': decDegrees,
    'v': magV,
    if (colorIndexBv != null) 'bv': colorIndexBv,
    if (magR != null) 'r': magR,
  };

  factory PhotometricCatalogStar.fromJson(Map<String, dynamic> json) {
    return PhotometricCatalogStar(
      raDegrees: (json['ra'] as num).toDouble(),
      decDegrees: (json['dec'] as num).toDouble(),
      magV: (json['v'] as num).toDouble(),
      colorIndexBv: (json['bv'] as num?)?.toDouble(),
      magR: (json['r'] as num?)?.toDouble(),
    );
  }
}

/// Cone-search result with provenance — the caller stamps [source] into
/// calibration rows and the MAGZPSRC FITS keyword.
class PhotometricConeResult {
  final PhotometricCatalogSource source;
  final List<PhotometricCatalogStar> stars;

  const PhotometricConeResult({required this.source, required this.stars});
}

/// Deep photometric catalog access for zero-point calibration and the
/// transform wizard.
///
/// Priority order for a cone search:
///   1. **APASS DR9 cache** — previous downloads stored as JSON under the
///      app-support directory, keyed on a coarse pointing grid so dithered
///      frames of the same field reuse one entry. Works fully offline.
///   2. **APASS DR9 online** (VizieR cone search, `II/336/apass9`) — B and
///      V photometry to roughly magnitude 17, which is what actually
///      matches the star counts of an amateur astrograph frame. Results
///      are written into the cache before being returned.
///   3. **Bundled HYG catalog** — offline fallback (V to ~mag 9, B-V for
///      most entries). Shallow, but always available.
///
/// The online step can be disabled with the
/// `science.catalog.online_apass_enabled` setting (default on); the
/// service then runs cache → HYG only, so a remote dark-site appliance
/// never blocks a capture pipeline waiting on a dead uplink. Every network
/// failure degrades silently (logged) to the next source — photometry keeps
/// flowing on HYG rather than erroring out.
class PhotometricCatalogService {
  static const onlineEnabledSettingKey = 'science.catalog.online_apass_enabled';

  /// VizieR mirror used for the APASS cone search.
  static const _vizierBases = [
    'https://vizier.cds.unistra.fr/viz-bin/asu-tsv',
    'https://vizier.cfa.harvard.edu/viz-bin/asu-tsv',
  ];

  /// Cache grid: pointing rounded to this many degrees, radius rounded UP
  /// to the next multiple. Combined with [_radiusPaddingDeg] this makes a
  /// dither pattern (arcminutes) hit a single cached cone.
  static const _gridDeg = 0.2;
  static const _radiusPaddingDeg = 0.15;

  static const _requestTimeout = Duration(seconds: 6);

  /// Hard ceiling on rows requested from VizieR per cone. A padded cone
  /// around a rich field holds about 6000 APASS stars; a response that
  /// reaches the ceiling is truncated, so it is used but not cached.
  static const _maxRows = 20000;

  final Ref _ref;
  final http.Client _client;
  final DateTime Function() _now;
  final Map<String, DateTime> _retryAfter = {};
  static const _failureCooldown = Duration(minutes: 5);

  /// In-flight de-duplication: concurrent stages asking for the same cone
  /// (calibration + residuals of one frame) share a single fetch.
  final Map<String, Future<List<PhotometricCatalogStar>?>> _inflight = {};

  PhotometricCatalogService(
    this._ref, {
    http.Client? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Cone search with APASS-first, HYG-fallback semantics. Stars are
  /// filtered to [maxMagnitude] (V) and the REQUESTED cone even when served
  /// from a padded cache entry.
  Future<PhotometricConeResult> coneSearch({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 16.0,
  }) async {
    final radius = radiusDegrees.clamp(0.05, 8.0).toDouble();
    final apass = await _apassCone(
      raDegrees: raDegrees,
      decDegrees: decDegrees,
      radiusDegrees: radius,
    );
    if (apass != null && apass.isNotEmpty) {
      final filtered = _filterCone(
        apass,
        raDegrees: raDegrees,
        decDegrees: decDegrees,
        radiusDegrees: radius,
        maxMagnitude: maxMagnitude,
      );
      // A cone that came back essentially empty after filtering (galactic
      // pole hole in APASS, saturated bright field) is not better than
      // HYG — require a usable minimum before claiming APASS provenance.
      if (filtered.length >= 8) {
        return PhotometricConeResult(
          source: PhotometricCatalogSource.localApass,
          stars: filtered,
        );
      }
    }
    return PhotometricConeResult(
      source: PhotometricCatalogSource.localHyg,
      stars: await _hygCone(
        raDegrees: raDegrees,
        decDegrees: decDegrees,
        radiusDegrees: radius,
        maxMagnitude: maxMagnitude,
      ),
    );
  }

  // ── APASS (cache + online) ────────────────────────────────────────────

  Future<List<PhotometricCatalogStar>?> _apassCone({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
  }) {
    // Snap to the cache grid so nearby pointings share an entry.
    final gridRa = (raDegrees / _gridDeg).round() * _gridDeg;
    final gridDec = (decDegrees / _gridDeg).round() * _gridDeg;
    final paddedRadius =
        ((radiusDegrees + _radiusPaddingDeg) / 0.25).ceil() * 0.25;
    final cell =
        '${gridRa.toStringAsFixed(1)}_${gridDec.toStringAsFixed(1)}_${paddedRadius.toStringAsFixed(2)}';
    // Entries under the older key were fetched without r'; they still serve
    // B and V when the current entry cannot be fetched.
    final key = 'apass9r_$cell';
    final legacyKey = 'apass9_$cell';

    return _inflight.putIfAbsent(key, () async {
      try {
        final cached = await _readCache(key);
        if (cached != null) {
          return cached;
        }
        if (!await _onlineEnabled()) {
          return await _readCache(legacyKey);
        }
        final fetched = await _fetchApass(
          raDegrees: gridRa,
          decDegrees: gridDec,
          radiusDegrees: paddedRadius,
        );
        if (fetched != null) {
          // A truncated cone is used for this frame but not kept, so the
          // next frame asks again rather than reusing an incomplete list.
          if (fetched.length < _maxRows) await _writeCache(key, fetched);
          return fetched;
        }
        return await _readCache(legacyKey);
      } catch (error, stack) {
        _logger.warning(
          'APASS cone $key failed; falling back to bundled catalog: '
          '$error\n$stack',
          source: 'PhotometricCatalogService',
        );
        return null;
      } finally {
        unawaited(_inflight.remove(key));
      }
    });
  }

  /// Test seam for the online-catalog gate. Production code reaches this
  /// through [_onlineEnabled]; tests use it to assert the fail-closed default.
  @visibleForTesting
  Future<bool> debugOnlineEnabled() => _onlineEnabled();

  Future<bool> _onlineEnabled() async {
    try {
      final stored = await _ref
          .read(settingsDaoProvider)
          .getSetting(onlineEnabledSettingKey);
      return stored == null || stored.toLowerCase() != 'false';
    } catch (error, stack) {
      // Fail closed: if the setting read faults we must not silently enable
      // network egress. A persistently failing read is diagnosable here.
      _logger.warning(
        'Online-catalog gate read failed; defaulting to offline: $error\n$stack',
        source: 'PhotometricCatalogService',
      );
      return false;
    }
  }

  Future<List<PhotometricCatalogStar>?> _fetchApass({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
  }) async {
    for (final base in _vizierBases) {
      final retry = _retryAfter[base];
      if (retry != null && _now().isBefore(retry)) continue;
      try {
        final stars = await _fetchApassFrom(
          base,
          raDegrees: raDegrees,
          decDegrees: decDegrees,
          radiusDegrees: radiusDegrees,
        );
        if (stars != null) {
          _retryAfter.remove(base);
          return stars;
        }
      } catch (error) {
        _logger.warning(
          'APASS at $base unavailable: $error; retrying after 5 minutes.',
          source: 'PhotometricCatalogService',
        );
      }
      _retryAfter[base] = _now().add(_failureCooldown);
    }
    return null;
  }

  Future<List<PhotometricCatalogStar>?> _fetchApassFrom(
    String base, {
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
  }) async {
    final uri = Uri.parse(base).replace(
      queryParameters: {
        '-source': 'II/336/apass9',
        '-c':
            '${raDegrees.toStringAsFixed(5)} '
            '${decDegrees.toStringAsFixed(5)}',
        '-c.rd': radiusDegrees.toStringAsFixed(3),
        '-out': "RAJ2000 DEJ2000 Vmag Bmag r'mag",
        '-out.max': '$_maxRows',
        // Drop rows without a V magnitude server-side.
        'Vmag': '>0',
      },
    );
    final response = await _client
        .get(uri, headers: const {'User-Agent': 'Skotiq'})
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      _logger.warning(
        'VizieR APASS query returned HTTP ${response.statusCode}',
        source: 'PhotometricCatalogService',
      );
      return null;
    }
    if (!response.body
        .split('\n')
        .any(
          (line) =>
              line.split('\t').map((cell) => cell.trim()).contains('RAJ2000'),
        )) {
      _logger.warning(
        'APASS at $base returned no catalog table.',
        source: 'PhotometricCatalogService',
      );
      return null;
    }
    final stars = _parseVizierTsv(response.body);
    if (stars.length >= _maxRows) {
      _logger.warning(
        'APASS cone ${raDegrees.toStringAsFixed(2)}/'
        '${decDegrees.toStringAsFixed(2)} hit the $_maxRows-row limit; the '
        'cone is incomplete and is not cached.',
        source: 'PhotometricCatalogService',
      );
    }
    _logger.info(
      'APASS cone ${raDegrees.toStringAsFixed(2)}/'
      '${decDegrees.toStringAsFixed(2)} r=${radiusDegrees.toStringAsFixed(2)}° '
      'fetched ${stars.length} stars from VizieR.',
      source: 'PhotometricCatalogService',
    );
    return stars;
  }

  /// Parse the VizieR `asu-tsv` format: `#`-prefixed comments, a
  /// tab-separated header row, a `---` separator row, then data rows.
  /// Exposed for tests.
  static List<PhotometricCatalogStar> parseVizierTsv(String body) =>
      _parseVizierTsv(body);

  static List<PhotometricCatalogStar> _parseVizierTsv(String body) {
    final stars = <PhotometricCatalogStar>[];
    List<String>? columns;
    for (final rawLine in const LineSplitter().convert(body)) {
      final line = rawLine.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (columns == null) {
        final candidate = line.split('\t').map((c) => c.trim()).toList();
        if (candidate.contains('RAJ2000')) {
          columns = candidate;
        }
        continue;
      }
      if (line.startsWith('-')) continue; // header/data separator row
      final cells = line.split('\t').map((c) => c.trim()).toList();
      // A row can legitimately be short when the trailing Bmag is absent;
      // require only the positional + V columns and let cell() guard the
      // rest. (The units row "deg deg mag mag" falls out naturally because
      // its cells don't parse as numbers.)
      if (cells.length < 3) continue;
      double? cell(String name) {
        final index = columns!.indexOf(name);
        if (index < 0 || index >= cells.length) return null;
        return double.tryParse(cells[index]);
      }

      final ra = cell('RAJ2000');
      final dec = cell('DEJ2000');
      final v = cell('Vmag');
      if (ra == null || dec == null || v == null || !v.isFinite) continue;
      final b = cell('Bmag');
      final r = cell("r'mag");
      stars.add(
        PhotometricCatalogStar(
          raDegrees: ra,
          decDegrees: dec,
          magV: v,
          colorIndexBv: (b != null && b.isFinite) ? b - v : null,
          magR: (r != null && r.isFinite) ? r : null,
        ),
      );
    }
    return stars;
  }

  // ── HYG fallback ──────────────────────────────────────────────────────

  Future<List<PhotometricCatalogStar>> _hygCone({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    required double maxMagnitude,
  }) async {
    final manager = CatalogManager.instance;
    if (!manager.isInitialized) return const [];
    final nearby = await manager.searchStarsNearby(
      ra: raDegrees,
      dec: decDegrees,
      radiusDegrees: radiusDegrees,
      maxMagnitude: maxMagnitude,
    );
    final stars = <PhotometricCatalogStar>[];
    for (final star in nearby) {
      final magV = star.magnitude;
      if (magV == null || !magV.isFinite) continue;
      double? bv;
      if (star.colorIndex != null && star.colorIndex!.isFinite) {
        bv = star.colorIndex;
      } else if (star.spectralType != null && star.spectralType!.isNotEmpty) {
        bv = bvFromSpectralType(star.spectralType!);
      }
      stars.add(
        PhotometricCatalogStar(
          raDegrees: star.ra,
          decDegrees: star.dec,
          magV: magV,
          colorIndexBv: bv,
        ),
      );
    }
    return stars;
  }

  /// Estimate B-V from an MK spectral type (main-sequence values from
  /// Allen's Astrophysical Quantities, interpolated on the subtype digit).
  /// Returns null when the type cannot be parsed.
  static double? bvFromSpectralType(String spectralType) {
    if (spectralType.isEmpty) return null;
    const classBv = {
      'O': -0.33,
      'B': -0.20,
      'A': 0.00,
      'F': 0.30,
      'G': 0.58,
      'K': 0.81,
      'M': 1.40,
    };
    const classOrder = ['O', 'B', 'A', 'F', 'G', 'K', 'M'];
    final letter = spectralType[0].toUpperCase();
    final classIdx = classOrder.indexOf(letter);
    if (classIdx < 0) return null;
    final baseBv = classBv[letter]!;
    double subtype = 0.0;
    if (spectralType.length > 1) {
      final parsed = double.tryParse(spectralType[1]);
      if (parsed != null) subtype = parsed.clamp(0.0, 9.0);
    }
    if (classIdx < classOrder.length - 1) {
      final nextBv = classBv[classOrder[classIdx + 1]]!;
      return baseBv + (nextBv - baseBv) * (subtype / 10.0);
    }
    return baseBv + 0.06 * (subtype / 10.0);
  }

  // ── Cache ─────────────────────────────────────────────────────────────

  Future<Directory> _cacheDirectory() async {
    final base = await resolveSkotiqDataDirectory();
    final dir = Directory(p.join(base.path, 'catalog_cache', 'apass_v1'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<PhotometricCatalogStar>?> _readCache(String key) async {
    try {
      final dir = await _cacheDirectory();
      final file = File(p.join(dir.path, '$key.json'));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map(
            (entry) =>
                PhotometricCatalogStar.fromJson(entry.cast<String, dynamic>()),
          )
          .toList(growable: false);
    } catch (error) {
      _logger.warning(
        'Discarding unreadable APASS cache entry $key: $error',
        source: 'PhotometricCatalogService',
      );
      return null;
    }
  }

  Future<void> _writeCache(
    String key,
    List<PhotometricCatalogStar> stars,
  ) async {
    try {
      final dir = await _cacheDirectory();
      final file = File(p.join(dir.path, '$key.json'));
      await file.writeAsString(
        jsonEncode(stars.map((star) => star.toJson()).toList(growable: false)),
        flush: true,
      );
    } catch (error) {
      // Cache misses are recoverable; a failed write only costs a re-fetch.
      _logger.warning(
        'Failed to write APASS cache entry $key: $error',
        source: 'PhotometricCatalogService',
      );
    }
  }

  List<PhotometricCatalogStar> _filterCone(
    List<PhotometricCatalogStar> stars, {
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    required double maxMagnitude,
  }) {
    final cosDec0 = math.cos(decDegrees * math.pi / 180.0);
    final radiusSq = radiusDegrees * radiusDegrees;
    return stars
        .where((star) {
          if (star.magV > maxMagnitude) return false;
          var dRa = (star.raDegrees - raDegrees).abs();
          if (dRa > 180.0) dRa = 360.0 - dRa;
          final dx = dRa * cosDec0;
          final dy = star.decDegrees - decDegrees;
          return dx * dx + dy * dy <= radiusSq;
        })
        .toList(growable: false);
  }
}

final photometricCatalogServiceProvider = Provider<PhotometricCatalogService>((
  ref,
) {
  return PhotometricCatalogService(ref);
});
