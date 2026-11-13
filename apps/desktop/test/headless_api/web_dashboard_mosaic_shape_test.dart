// The web dashboard's mosaic wizard writes its request bodies as JavaScript
// object literals, and the host reads them key by key, ignoring any key it
// does not know. A key the host renamed would leave the dashboard sending a
// setting nobody reads. These checks read both sides' source and keep the key
// sets in step.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _appJs = File('web_dashboard/js/app.js').readAsStringSync();
final _handlers = File(
  'lib/headless_api/handlers/mosaic_handlers.dart',
).readAsStringSync();

/// The body of the host parser [name]: from its signature to the end of the
/// method.
String _hostParser(String name) {
  final start = _handlers.indexOf('$name(Map<String, dynamic> json) {');
  expect(start, isNonNegative, reason: '$name must exist on the host');
  return _handlers.substring(start, _handlers.indexOf('\n  }\n', start));
}

/// The keys [parser] reads, and the ones of those it requires.
({Set<String> all, Set<String> required}) _hostKeys(String parser) {
  final body = _hostParser(parser);
  final reads = RegExp(
    r"(require|optional)\w+\(\s*json,\s*'(\w+)'",
  ).allMatches(body);
  return (
    all: {for (final m in reads) m.group(2)!},
    required: {
      for (final m in reads)
        if (m.group(1) == 'require') m.group(2)!,
    },
  );
}

/// The dashboard function [name], lifted out of app.js by its indent.
String _dashboardFunction(String name) {
  final match = RegExp(
    '  (?:async )?function $name\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}',
  ).firstMatch(_appJs);
  expect(match, isNotNull, reason: '$name must exist in app.js');
  return match!.group(0)!;
}

/// The top-level keys of the object literal that follows [opener] in
/// [source].
Set<String> _literalKeys(String source, String opener) {
  final start = source.indexOf(opener);
  expect(start, isNonNegative, reason: '`$opener` must be in the dashboard');
  var depth = 0;
  var end = start + opener.length - 1;
  for (; end < source.length; end++) {
    final c = source[end];
    if (c == '{' || c == '(' || c == '[') depth++;
    if (c == '}' || c == ')' || c == ']') depth--;
    if (depth == 0) break;
  }
  final literal = source.substring(start + opener.length, end);
  return {
    for (final line in literal.split('\n'))
      if (RegExp(r'^\s*(\w+):').firstMatch(line) case final m?
          when !line.trimLeft().startsWith('//'))
        m.group(1)!,
  };
}

void main() {
  test('the dashboard sends every mosaic layout setting the host reads', () {
    final config = _hostKeys('_parseMosaicConfig');
    final sent = _literalKeys(
      _dashboardFunction('readMosaicConfig'),
      'return {',
    );
    expect(sent, config.all);
    expect(sent, containsAll(['startCorner', 'serpentine']));
  });

  test('the exposure the dashboard sends is the host\'s shape', () {
    final config = _hostKeys('_parseMosaicConfig');
    final exposure = _hostKeys('_parseExposureSettings');
    final build = _dashboardFunction('handleMosaicBuild');
    final preview = _dashboardFunction('handleMosaicPreview');
    for (final sent in [
      _literalKeys(build, 'const exposure = {'),
      _literalKeys(preview, 'api.mosaicEstimateTime(config, {'),
    ]) {
      expect(config.all.intersection(sent), isEmpty);
      expect(exposure.all, containsAll(sent));
      expect(sent, containsAll(exposure.required));
    }
  });

  test('every sequence option the dashboard sends is one the host reads', () {
    final options = _hostKeys('_parseSequenceOptions');
    final sent = _literalKeys(
      _dashboardFunction('handleMosaicBuild'),
      'options: {',
    );
    expect(sent, isNotEmpty);
    expect(options.all, containsAll(sent));
  });
}
