// Every character the UI writes must be in a bundled face: a text face or a
// face of `SkotiqTypography.fontFamilyFallback`. A machine whose system fonts
// lack a character otherwise draws a box (a widget test and a minimal Linux
// install both do).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_design/skotiq_design.dart';

/// The bundled font file of each family the typography names.
const _files = {
  'HankenGrotesk': 'HankenGrotesk-VF.ttf',
  'SplineSansMono': 'SplineSansMono-VF.ttf',
  'Sora': 'Sora-VF.ttf',
  'SkotiqSymbols': 'SkotiqSymbols-Regular.ttf',
};

/// The code points a TrueType font maps, from its Unicode cmap subtables
/// (formats 4 and 12).
Set<int> _codePoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    if (String.fromCharCodes(bytes, record, record + 4) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  expect(cmap, isNot(-1), reason: 'no cmap table');
  final out = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final offset = cmap + data.getUint32(cmap + 4 + i * 8 + 4);
    switch (data.getUint16(offset)) {
      case 4:
        final segments = data.getUint16(offset + 6) ~/ 2;
        final ends = offset + 14;
        final starts = ends + segments * 2 + 2;
        final deltas = starts + segments * 2;
        final ranges = deltas + segments * 2;
        for (var s = 0; s < segments; s++) {
          final end = data.getUint16(ends + s * 2);
          final start = data.getUint16(starts + s * 2);
          final delta = data.getUint16(deltas + s * 2);
          final range = data.getUint16(ranges + s * 2);
          for (var c = start; c <= end && c != 0xFFFF; c++) {
            var glyph = 0;
            if (range == 0) {
              glyph = (c + delta) & 0xFFFF;
            } else {
              final at = ranges + s * 2 + range + (c - start) * 2;
              glyph = data.getUint16(at);
              if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
            }
            if (glyph != 0) out.add(c);
          }
        }
      case 12:
        final groups = data.getUint32(offset + 12);
        for (var g = 0; g < groups; g++) {
          final at = offset + 16 + g * 12;
          final start = data.getUint32(at);
          final end = data.getUint32(at + 4);
          for (var c = start; c <= end; c++) {
            out.add(c);
          }
        }
    }
  }
  return out;
}

void main() {
  test('the bundled faces have every sign and symbol the UI writes', () {
    final families = {
      SkotiqTypography.fontFamily,
      SkotiqTypography.fontFamilyMono,
      ...SkotiqTypography.fontFamilyFallback,
    };
    final covered = <int>{};
    for (final family in families) {
      final file = _files[family];
      expect(file, isNotNull, reason: '$family has no bundled file');
      covered.addAll(_codePoints(File('assets/fonts/$file').readAsBytesSync()));
    }

    // Read noise and full well in e⁻, menu paths with ▸, seeing in σ, the
    // primes of angles and RMS, arrows, stars and the info and command signs.
    const used = '⁻▸σΑ′″ʹʺ↑↓↻★ⓘ⌘ ‑°µ×→←·–—…';
    final missing = [
      for (final rune in used.runes)
        if (!covered.contains(rune))
          'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')} '
              '${String.fromCharCode(rune)}',
    ];
    expect(missing, isEmpty);
  });
}
