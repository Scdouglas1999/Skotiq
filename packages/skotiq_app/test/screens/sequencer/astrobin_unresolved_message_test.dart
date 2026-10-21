// An Astrobin import that leaves subjects unresolved names them and says why,
// instead of only counting them.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/import_sequence_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('names each unresolved subject with its reason', () {
    final message = astrobinUnresolvedMessage(2, const [
      UnresolvedTarget(designation: 'Orion M42 widefield', rowNum: 2),
      UnresolvedTarget(
        designation: 'Twin',
        rowNum: 3,
        reason: 'several catalog objects are named "Twin" (A, B)',
      ),
    ]);

    expect(message, contains('2 resolved'));
    expect(message,
        contains('"Orion M42 widefield" matches no catalog object by name'));
    expect(message, contains('several catalog objects are named "Twin"'));
    expect(message, contains('RA 0 / Dec 0'));
  });
}
