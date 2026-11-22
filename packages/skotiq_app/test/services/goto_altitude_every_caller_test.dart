// Every GoTo the app sends goes through MountCommandService.slewTo, whose
// altitude question (P7-1) is then met by every caller: the planetarium, the
// info tab, Tonight, the sequencer toolbar, First Light, the slew button and
// the gyroscope pointing. A new path that slewed past it would be a GoTo
// that never asks.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('only the mount service sends a GoTo to the device service', () {
    final senders = [
      for (final file in sources)
        if (file.readAsStringSync().contains('slewMountToCoordinates'))
          file.path,
    ];
    expect(senders, ['lib/services/mount_command_service.dart']);
  });

  test('only the mount service defines slewTo', () {
    final definers = [
      for (final file in sources)
        if (RegExp(r'Future<CommandActionResult> slewTo\(')
            .hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(definers, ['lib/services/mount_command_service.dart']);
  });

  // A mis-tap or a mis-press must never move the mount without a question:
  // these two callers ask for every GoTo, and the warning rides on that one
  // question when the target is low.
  for (final path in [
    'lib/screens/planetarium/planetarium_screen/actions.dart',
    'lib/screens/sequencer/widgets/sequence_toolbar.dart',
  ]) {
    test('$path always confirms its GoTo', () {
      expect(File(path).readAsStringSync(), contains('alwaysConfirms: true'));
    });
  }
}
