/// Readable summaries of the structured parameters a draft measures.
///
/// `channel_combine@1` stores what the draft measured — each master's
/// registration, the common area, the flux matching — as JSON objects the
/// editor does not edit. They are summarized line by line here so the step card
/// says what was combined and how, instead of printing a JSON dump with full
/// file paths.
library;

import 'dart:math' as math;

/// The lines summarizing parameter [name] holding [value].
///
/// A value of a shape this does not recognize is printed as its JSON text,
/// which is still the truth about the step.
List<String> darkroomMeasuredValueLines(String name, Object? value) {
  if (value == null) return const ['no value stored'];
  switch (name) {
    case 'inputs':
      if (value is List) {
        return [for (final input in value) _inputLine(input)];
      }
    case 'crop':
      if (value is Map) {
        final w = _int(value['width']);
        final h = _int(value['height']);
        final x = _int(value['x']);
        final y = _int(value['y']);
        if (w != null && h != null && x != null && y != null) {
          return ['$w x $h px, starting at ($x, $y) on the reference master'];
        }
      }
    case 'fits':
      if (value is Map) {
        if (value.isEmpty) return const ['measured on every render'];
        return [
          for (final entry in value.entries)
            if (entry.value is Map)
              '${_fitName('${entry.key}')}: scale '
                  '${_num((entry.value as Map)['scale'], 4)}, offset '
                  '${_num((entry.value as Map)['offset'], 1)}',
        ];
      }
    case 'starSigma':
      if (value is Map) {
        return [
          for (final entry in value.entries)
            '${_roleName('${entry.key}')} stars: half-flux radius '
                '${_num(_halfFlux(entry.value), 2)} px',
        ];
      }
  }
  return ['$value'];
}

String _inputLine(Object? input) {
  if (input is! Map) return '$input';
  final role = _roleName('${input['role']}');
  final filter = input['filter'];
  final name =
      filter is String && filter.trim().isNotEmpty ? '$filter ($role)' : role;
  final path = '${input['path'] ?? ''}';
  final file = path.split(RegExp(r'[\\/]')).last;
  if (input['reference'] == true) {
    return '$name: the reference, $file';
  }
  final t = input['transform'];
  if (t is List && t.length == 6 && t.every((v) => v is num)) {
    final m = [for (final v in t) (v as num).toDouble()];
    final rotation =
        (math.atan2(m[3], m[0]) * 180.0 / math.pi).toStringAsFixed(3);
    return '$name: shifted ${m[2].toStringAsFixed(1)}, '
        '${m[5].toStringAsFixed(1)} px, rotated $rotation°, $file';
  }
  return '$name: $file';
}

String _roleName(String role) => switch (role) {
      'luminance' => 'luminance',
      'red' => 'red',
      'green' => 'green',
      'blue' => 'blue',
      'hAlpha' => 'Ha',
      'oiii' => 'OIII',
      'sii' => 'SII',
      'color' => 'one-shot color',
      _ => role,
    };

String _fitName(String key) {
  switch (key) {
    case 'luminanceToRgb':
      return 'Luminance matched to the RGB';
    case 'hAlphaToRed':
      return 'Ha matched to red';
    case 'hAlphaToLuminance':
      return 'Ha matched to the luminance';
    case 'oiiiToHAlpha':
      return 'OIII matched to Ha';
    case 'siiToHAlpha':
      return 'SII matched to Ha';
  }
  if (key.startsWith('session')) {
    return 'Master ${key.substring('session'.length)} matched to its filter\'s '
        'first master';
  }
  return key;
}

Object? _halfFlux(Object? sigma) =>
    sigma is num ? sigma.toDouble() * 1.1774100225154747 : sigma;

int? _int(Object? v) => v is num ? v.toInt() : null;

String _num(Object? v, int digits) =>
    v is num ? v.toDouble().toStringAsFixed(digits) : '$v';
