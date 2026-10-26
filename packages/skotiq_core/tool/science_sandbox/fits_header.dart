import 'dart:io';

/// The primary-header fields the sandbox registers a frame with.
class FitsFrameInfo {
  FitsFrameInfo._(this.path, this.header);

  final String path;
  final Map<String, String> header;

  /// Synced rig frames can carry the Windows path in their file name
  /// (`C:\Users\...\NGC0891_L_0150.fits`); the base name is the last part.
  String get baseName => path.split('/').last.split(r'\').last;

  static FitsFrameInfo read(String path) {
    final raf = File(path).openSync();
    try {
      final header = <String, String>{};
      var done = false;
      while (!done) {
        final block = raf.readSync(2880);
        if (block.length < 2880) throw const FormatException('short header');
        for (var i = 0; i < 36; i++) {
          final card = String.fromCharCodes(block.sublist(i * 80, i * 80 + 80));
          final key = card.substring(0, 8).trim();
          if (key == 'END') {
            done = true;
            break;
          }
          if (card.length < 10 || card.substring(8, 10) != '= ') continue;
          header[key] = _value(card.substring(10));
        }
      }
      return FitsFrameInfo._(path, header);
    } finally {
      raf.closeSync();
    }
  }

  static String _value(String raw) {
    final s = raw.trimLeft();
    if (s.startsWith("'")) {
      final end = s.indexOf("'", 1);
      return (end < 0 ? s.substring(1) : s.substring(1, end)).trim();
    }
    final slash = s.indexOf('/');
    return (slash < 0 ? s : s.substring(0, slash)).trim();
  }

  double? _d(String k) => double.tryParse(header[k] ?? '');
  int? _i(String k) => _d(k)?.round();

  String? get object => header['OBJECT'];
  String? get filter => header['FILTER'];
  double get exposure => _d('EXPTIME') ?? _d('EXPOSURE') ?? 0;
  int? get gain => _i('GAIN');
  int? get offset => _i('OFFSET');
  int? get binX => _i('XBINNING');
  int? get binY => _i('YBINNING');
  double? get ccdTemp => _d('CCD-TEMP');
  double? get raDeg => _d('RA');
  double? get decDeg => _d('DEC');
  double? get altitude => _d('OBJCTALT') ?? _d('CENTALT');
  int? get focusPos => _i('FOCUSPOS');
  double? get focusTemp => _d('FOCTEMP');

  double? get objRaDeg => _sexagesimal(header['OBJCTRA'], hours: true) ?? raDeg;
  double? get objDecDeg =>
      _sexagesimal(header['OBJCTDEC'], hours: false) ?? decDeg;

  /// Exposure start from DATE-OBS (UTC).
  DateTime get captureStart {
    final raw = header['DATE-OBS'];
    if (raw == null) throw const FormatException('no DATE-OBS');
    return DateTime.parse(raw.endsWith('Z') ? raw : '${raw}Z');
  }

  /// When the rig registers the frame: the sequencer stamps `captured_at`
  /// with the time the row is written, which is after the shutter closes.
  /// DATE-OBS + EXPTIME is the closest header-derived value.
  DateTime get captureEnd =>
      captureStart.add(Duration(milliseconds: (exposure * 1000).round()));

  /// Observing night as YYYY-MM-DD of the evening it started: noon-to-noon
  /// local, with local time taken from SITELONG (15 deg per hour).
  String get nightKey {
    final lon = _d('SITELONG') ?? 0;
    final local = captureEnd.add(
      Duration(minutes: (lon / 15 * 60).round() - 12 * 60),
    );
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  static double? _sexagesimal(String? s, {required bool hours}) {
    if (s == null) return null;
    final parts = s.trim().split(RegExp(r'[\s:]+'));
    if (parts.length < 3) return null;
    final sign = parts[0].startsWith('-') ? -1.0 : 1.0;
    final a = double.tryParse(parts[0].replaceAll(RegExp(r'^[+-]'), ''));
    final b = double.tryParse(parts[1]);
    final c = double.tryParse(parts[2]);
    if (a == null || b == null || c == null) return null;
    final v = sign * (a + b / 60 + c / 3600);
    return hours ? v * 15.0 : v;
  }
}
