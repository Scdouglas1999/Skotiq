// User-facing text is American English (qa-night N03): strings said "centre",
// "colour" and "catalogue".
import 'package:flutter_test/flutter_test.dart';

import 'source_literals.dart';

final _british = RegExp(r'\b(centre|colour|catalogue)\b', caseSensitive: false);

void main() {
  test('the app and core text uses American spelling', () {
    final offenders = [
      for (final literal in sourceLiterals(['lib', '../skotiq_core/lib']))
        if (_british.hasMatch(literal.text))
          '${literal.path}:${literal.line}: ${literal.text}',
    ];
    expect(offenders, isEmpty);
  });
}
