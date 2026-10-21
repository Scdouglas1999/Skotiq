import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// An object SIMBAD knows by the exact identifier that was asked for.
class ResolvedTargetName {
  /// SIMBAD's main identifier with its column padding collapsed
  /// (`M  42` becomes `M 42`, `NAME Heart Nebula` becomes `Heart Nebula`).
  final String mainId;
  final double raHours;
  final double decDegrees;
  final String? objectType;

  const ResolvedTargetName({
    required this.mainId,
    required this.raHours,
    required this.decDegrees,
    this.objectType,
  });
}

/// SIMBAD could not be asked: no network, a timeout, or a server error.
/// Distinct from "SIMBAD has no object by that name", which is a null result.
class TargetNameLookupUnavailable implements Exception {
  final String message;
  const TargetNameLookupUnavailable(this.message);

  @override
  String toString() => 'TargetNameLookupUnavailable: $message';
}

/// Exact name resolution through the CDS Sesame service, SIMBAD only.
///
/// Sesame resolves an identifier the way SIMBAD's own search box does: `m42`,
/// `M 42`, `Messier 42` and `Orion Nebula` all name `M  42`. It never does a
/// substring match, so it cannot answer "M42" with an object that merely has
/// "M42" inside one of its identifiers. That substring match (an ADQL
/// `main_id LIKE '%M42%'` with `TOP 1`) is what used to resolve "M42" to
/// "Cl* NGC 2516 HTR M42" and "[SSP2021] M42".
class SesameNameResolver {
  static const String endpoint =
      'https://cds.unistra.fr/cgi-bin/nph-sesame/-oxp/S';

  final http.Client? _client;
  final Duration timeout;

  SesameNameResolver({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client;

  /// SIMBAD spells a few catalogs differently from how observers type them:
  /// it knows `Barnard 33` but not `B33`, and `Collinder 399` but not `Cr 399`.
  static String simbadIdentifier(String name) {
    final trimmed = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    final designation = CatalogDesignation.parse(trimmed);
    return switch (designation?.catalog) {
      'B' => 'Barnard ${designation!.number}',
      'Cr' => 'Collinder ${designation!.number}',
      'Sh2' => 'Sh2-${designation!.number}',
      _ => trimmed,
    };
  }

  /// SIMBAD's main identifier as a person would write it.
  static String displayIdentifier(String mainId) => mainId
      .trim()
      .replaceFirst(RegExp(r'^NAME\s+'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Resolve [name] exactly. Returns null when SIMBAD has no such object;
  /// throws [TargetNameLookupUnavailable] when SIMBAD could not be reached.
  Future<ResolvedTargetName?> resolve(String name) async {
    final identifier = simbadIdentifier(name);
    if (identifier.isEmpty) return null;
    final uri = Uri.parse('$endpoint?${Uri.encodeComponent(identifier)}');
    final client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client.get(uri).timeout(timeout);
    } on TimeoutException {
      throw const TargetNameLookupUnavailable('SIMBAD did not answer in time');
    } on Exception catch (error) {
      throw TargetNameLookupUnavailable('could not reach SIMBAD ($error)');
    } finally {
      if (_client == null) client.close();
    }
    if (response.statusCode != 200) {
      throw TargetNameLookupUnavailable(
        'SIMBAD returned HTTP ${response.statusCode}',
      );
    }
    return parseSesameXml(response.body);
  }

  /// Parse a Sesame `-oxp` XML answer. Returns null when the resolver found
  /// nothing.
  static ResolvedTargetName? parseSesameXml(String body) {
    String? field(String tag) {
      final match = RegExp('<$tag>([^<]*)</$tag>').firstMatch(body);
      final value = match?.group(1)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    double? number(String tag) {
      final text = field(tag);
      return text == null ? null : double.tryParse(text);
    }

    final ra = number('jradeg');
    final dec = number('jdedeg');
    final oname = field('oname');
    if (ra == null || dec == null || oname == null) return null;
    return ResolvedTargetName(
      mainId: displayIdentifier(_unescape(oname)),
      raHours: ra / 15.0,
      decDegrees: dec,
      objectType: field('otype'),
    );
  }

  static String _unescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// The exact online name resolver. Overridden in tests with a fake client.
final sesameNameResolverProvider = Provider<SesameNameResolver>(
  (ref) => SesameNameResolver(),
);
