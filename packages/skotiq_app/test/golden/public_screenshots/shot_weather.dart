// The weather over the scene's site tonight: a clear sky. The satellite frame
// has no cloud within the alert radius and the forecast gives 0 % cloud; the
// map draws over recorded basemap tiles (see `test/fixtures/README.md`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../surface_golden_harness.dart';
import 'shot_night.dart';

/// The GOES IR frame the satellite provider builds for the site, the one
/// nearest the scene's now: no cloud anywhere in its analysis field.
RadarFrame clearSkyFrame() {
  final now = ShotNight.now.toUtc();
  const pad = 1.6;
  return RadarFrame(
    timestamp: DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      (now.minute ~/ 5) * 5,
    ),
    tileUrlTemplate:
        'https://mesonet.agron.iastate.edu/cgi-bin/wms/goes/conus_ir.cgi?',
    north: ShotNight.latitude + pad,
    south: ShotNight.latitude - pad,
    east: ShotNight.longitude + pad,
    west: ShotNight.longitude - pad,
    tileType: RadarTileType.wms,
    wmsLayers: 'conus_ir_4km',
    wmsAdditionalOptions: const {'transparent': 'true'},
    intensityGrid: List.generate(48, (_) => List<double>.filled(48, 0)),
  );
}

class _ClearSkyRadar extends WeatherRadarService {
  _ClearSkyRadar(super.ref);

  late final RadarFetchResult _result = RadarFetchResult.success(
    [clearSkyFrame()],
    providerName: 'GOES Satellite',
  );

  @override
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
    bool forceRefresh = false,
  }) async =>
      _result;

  @override
  RadarFetchResult? get lastSuccessfulResult => _result;

  @override
  List<RadarFrame>? getCachedFrames() => _result.frames;

  @override
  void clearCache() {}
}

class _ClearSky extends CurrentSkyService {
  @override
  Future<CurrentSky?> fetch({
    required double latitude,
    required double longitude,
  }) async =>
      CurrentSky(
        model: CloudCoverForecast(
          percent: 0,
          source: 'Open-Meteo',
          validAt: ShotNight.at(0, 23, 0).toUtc(),
        ),
      );
}

/// The site's weather for every shot: the rail's Weather item, Tonight's
/// conditions and the Weather screen read the same clear sky.
List<Override> clearSkyOverrides() => [
      weatherRadarServiceProvider.overrideWith((ref) {
        final service = _ClearSkyRadar(ref)..initialize();
        ref.onDispose(service.dispose);
        return service;
      }),
      // The forecast the night's last refresh evaluated, minutes ago: clear.
      weatherAlertServiceProvider.overrideWith((ref) {
        final service = WeatherAlertService()
          ..evaluateConditions(
            motion: null,
            currentCloudDensity: 0,
            settings: const WeatherSettings(weatherSafetyEnabled: true),
          );
        ref.onDispose(service.dispose);
        return service;
      }),
      currentSkyServiceProvider.overrideWith((ref) {
        final service = _ClearSky();
        ref.onDispose(service.dispose);
        return service;
      }),
    ];

/// Serves the map's tiles from the recorded basemap and an empty (clear)
/// satellite layer; every other address answers 404.
class MapTileServer extends HttpOverrides {
  MapTileServer()
      : _root = '${SurfaceGoldenHarness.repoRoot().path}'
            '/packages/skotiq_app/test/fixtures/weather_tiles';

  final String _root;

  /// Basemap tiles the map asked for that the fixture does not have.
  final Set<String> missing = {};

  static final Uint8List _clearTile = _transparentPng();

  @override
  HttpClient createHttpClient(SecurityContext? context) => _TileClient(this);

  (int, List<int>, String) _answer(Uri url) {
    if (url.host == 'services.arcgisonline.com') {
      // .../Canvas/World_Dark_Gray_{Base,Reference}/MapServer/tile/z/y/x
      final s = url.pathSegments;
      final layer =
          s[s.length - 6].endsWith('Reference') ? 'reference' : 'base';
      final key = '$layer/${s[s.length - 3]}/${s[s.length - 2]}/${s.last}';
      final file = File('$_root/$key.png');
      if (file.existsSync()) return (200, file.readAsBytesSync(), 'image/png');
      missing.add(key);
      return (404, const [], 'text/plain');
    }
    if (url.host == 'mesonet.agron.iastate.edu') {
      return (200, _clearTile, 'image/png');
    }
    return (404, const [], 'text/plain');
  }
}

/// A 256 x 256 fully transparent PNG: the IR layer over a clear sky.
Uint8List _transparentPng() {
  final raw = BytesBuilder();
  for (var y = 0; y < 256; y++) {
    raw.addByte(0);
    raw.add(Uint8List(256 * 4));
  }
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    final length = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, _crc32(body));
    return [
      ...length.buffer.asUint8List(),
      ...body,
      ...crc.buffer.asUint8List(),
    ];
  }

  final header = ByteData(13)
    ..setUint32(0, 256)
    ..setUint32(4, 256)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', header.buffer.asUint8List()),
    ...chunk('IDAT', zlib.encode(raw.takeBytes())),
    ...chunk('IEND', const []),
  ]);
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

class _TileClient implements HttpClient {
  _TileClient(this._server);

  final MapTileServer _server;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _TileRequest(_server, url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _TileRequest(_server, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TileRequest implements HttpClientRequest {
  _TileRequest(this._server, this.uri);

  final MapTileServer _server;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  bool bufferOutput = true;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() async {
    final (status, body, type) = _server._answer(uri);
    return _TileResponse(status, body, type);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TileResponse extends Stream<List<int>> implements HttpClientResponse {
  _TileResponse(this.statusCode, this._body, String type) {
    headers.set(HttpHeaders.contentTypeHeader, type);
  }

  final List<int> _body;

  @override
  final int statusCode;

  @override
  final HttpHeaders headers = _Headers();

  @override
  int get contentLength => _body.length;

  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Not Found';

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => true;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([_body]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = ['$value'];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      (_values[name.toLowerCase()] ??= []).add('$value');

  @override
  String? value(String name) => _values[name.toLowerCase()]?.first;

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
