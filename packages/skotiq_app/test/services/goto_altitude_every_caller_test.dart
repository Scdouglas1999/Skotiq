// Every GoTo the app sends goes through MountCommandService.slewTo, whose
// altitude question is then met by every caller: the planetarium, the
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

  // A mis-tap on the sky must never move the mount without a question; the
  // warning rides on that one question when the target is low. The toolbar's
  // Slew pins the same rule by behavior in sequence_toolbar_slew_test.dart.
  test('a tap on the planetarium sky always confirms its GoTo', () {
    expect(
      File('lib/screens/planetarium/planetarium_screen/actions.dart')
          .readAsStringSync(),
      contains('alwaysConfirms: true'),
    );
  });
}
