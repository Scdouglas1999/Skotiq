import 'dart:io';

import 'package:path/path.dart' as p;

/// One string literal in a Dart source file, with its interpolations removed.
typedef SourceLiteral = ({String path, int line, String text});

final _literal = RegExp(r"'[^']*'" '|' r'"[^"]*"');
final _interpolation = RegExp(r'\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*');

/// Every single-line string literal outside comments in the Dart files under
/// [roots] (paths relative to this package). The text is what the user would
/// read, so `${…}` and `$name` interpolations are dropped: an identifier is not
/// copy.
Iterable<SourceLiteral> sourceLiterals(List<String> roots) sync* {
  for (final root in roots) {
    final files = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final path = p.posix.joinAll(p.split(file.path));
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//') || line.startsWith('*')) continue;
        for (final match in _literal.allMatches(line)) {
          yield (
            path: path,
            line: i + 1,
            text: match.group(0)!.replaceAll(_interpolation, ''),
          );
        }
      }
    }
  }
}
