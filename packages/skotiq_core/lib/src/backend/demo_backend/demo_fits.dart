import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import 'demo_star_field.dart';

/// Encode a 16-bit mono frame as a FITS file: unsigned samples stored as
/// signed with BZERO 32768, as cameras write them. [cards] are extra header
/// keywords in order; a string value is quoted, a number or bool is not.
Uint8List encodeDemoFits({
  required int width,
  required int height,
  required Uint16List samples,
  required List<(String, Object, String?)> cards,
}) {
  final header = StringBuffer();
  void card(String key, Object value, [String? comment]) {
    final String text;
    if (value is String) {
      final quoted = "'${value.replaceAll("'", "''")}'";
      text = quoted.padRight(20);
    } else if (value is bool) {
      text = (value ? 'T' : 'F').padLeft(20);
    } else {
      text = '$value'.padLeft(20);
    }
    var line = '${key.padRight(8)}= $text';
    if (comment != null) line = '$line / $comment';
    header.write(_fit(line));
  }

  card('SIMPLE', true, 'conforms to FITS standard');
  card('BITPIX', 16, 'array data type');
  card('NAXIS', 2, 'number of array dimensions');
  card('NAXIS1', width);
  card('NAXIS2', height);
  card('BZERO', 32768, 'offset data range to that of unsigned short');
  card('BSCALE', 1, 'default scaling factor');
  for (final (key, value, comment) in cards) {
    card(key, value, comment);
  }
  header.write(
    _fit('COMMENT Synthetic frame from the Skotiq demo rig. Not a real sky.'),
  );
  header.write(_fit('END'));

  final headerBytes = _padTo2880(ascii.encode(header.toString()), 0x20);
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i] - 32768, Endian.big);
  }
  final dataBytes = _padTo2880(data.buffer.asUint8List(), 0);
  return (BytesBuilder(copy: false)
        ..add(headerBytes)
        ..add(dataBytes))
      .takeBytes();
}

/// [value] (hours or degrees) as `HH MM SS.ss`, the native writer's form for
/// `OBJCTRA` and `OBJCTDEC`; [signed] always shows the sign.
String demoSexagesimal(double value, {bool signed = false}) {
  final negative = value < 0;
  var total = value.abs() * 3600.0;
  total = (total * 100).round() / 100;
  final units = (total / 3600).floor();
  final minutes = ((total - units * 3600) / 60).floor();
  final seconds = total - units * 3600 - minutes * 60;
  final sign = signed ? (negative ? '-' : '+') : (negative ? '-' : '');
  String two(int n) => n.toString().padLeft(2, '0');
  return '$sign${two(units)} ${two(minutes)} '
      '${seconds.toStringAsFixed(2).padLeft(5, '0')}';
}

String _fit(String line) {
  final ascii7 = line.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
  return ascii7.length >= 80 ? ascii7.substring(0, 80) : ascii7.padRight(80);
}

Uint8List _padTo2880(List<int> bytes, int fill) {
  final padded = (bytes.length + 2879) ~/ 2880 * 2880;
  final out = Uint8List(padded)..fillRange(0, padded, fill);
  out.setRange(0, bytes.length, bytes);
  return out;
}

/// Read a frame the demo rig saved ([encodeDemoFits]) for the screen, with
/// the stretch and measurements its live frame had. Reads only what the demo
/// writes: a 16-bit mono image with BZERO 32768. The phone carries no native
/// FITS reader; this one exists so a saved demo frame opens there.
Future<bridge.FitsReadResult> readDemoFitsFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final cards = <String, String>{};
  var offset = 0;
  var ended = false;
  while (!ended && offset + 80 <= bytes.length) {
    final line = ascii.decode(
      bytes.sublist(offset, offset + 80),
      allowInvalid: true,
    );
    offset += 80;
    final key = line.substring(0, 8).trim();
    if (key == 'END') {
      ended = true;
    } else if (line.length > 10 && line.substring(8, 10) == '= ') {
      cards[key] = _cardValue(line.substring(10));
    }
  }
  int number(String key) {
    final text = cards[key];
    final value = text == null ? null : int.tryParse(text);
    if (value == null) throw FormatException('No $key in $path');
    return value;
  }

  if (!ended ||
      number('BITPIX') != 16 ||
      number('NAXIS') != 2 ||
      number('BZERO') != 32768) {
    throw FormatException('$path is not a frame the demo rig saved');
  }
  final width = number('NAXIS1');
  final height = number('NAXIS2');
  final dataStart = (offset + 2879) ~/ 2880 * 2880;
  final n = width * height;
  if (dataStart + n * 2 > bytes.length) {
    throw FormatException('$path ends before its image does');
  }
  final data = ByteData.sublistView(bytes, dataStart, dataStart + n * 2);
  final raw = Uint16List(n);
  for (var i = 0; i < n; i++) {
    raw[i] = data.getInt16(i * 2, Endian.big) + 32768;
  }
  final frame = measureDemoSamples(width: width, height: height, raw: raw);
  return bridge.FitsReadResult(
    width: width,
    height: height,
    bitpix: 16,
    displayData: frame.displayRgba,
    histogram: Uint32List.fromList(frame.histogram),
    stats: bridge.ImageStatsResult(
      min: frame.min,
      max: frame.max,
      mean: frame.mean,
      median: frame.median,
      stdDev: frame.stdDev,
      starCount: frame.starCount,
    ),
    objectName: cards['OBJECT'],
    exposureTime: _real(cards['EXPTIME']),
    filter: cards['FILTER'],
    ra: _real(cards['RA']),
    dec: _real(cards['DEC']),
    dateObs: cards['DATE-OBS'],
  );
}

/// A numeric card's value, or null when the card is absent or not a number.
double? _real(String? text) => text == null ? null : double.tryParse(text);

/// A card's value without its comment; a quoted string unquoted.
String _cardValue(String field) {
  final text = field.trimLeft();
  if (text.startsWith("'")) {
    final out = StringBuffer();
    for (var i = 1; i < text.length; i++) {
      if (text[i] == "'") {
        if (i + 1 < text.length && text[i + 1] == "'") {
          out.write("'");
          i++;
          continue;
        }
        break;
      }
      out.write(text[i]);
    }
    return out.toString().trimRight();
  }
  final slash = text.indexOf('/');
  return (slash < 0 ? text : text.substring(0, slash)).trim();
}
