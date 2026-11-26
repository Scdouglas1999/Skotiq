import 'dart:convert';
import 'dart:typed_data';

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
