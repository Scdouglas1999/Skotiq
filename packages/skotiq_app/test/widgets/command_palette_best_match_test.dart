// Live (u1-audit): "polar" + Enter opened Plan > Framing on a cluster whose
// common name holds the word, not the Polar alignment screen.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_entry.dart';

CommandEntry _entry(String id, CommandGroup group, String label) =>
    CommandEntry(
      id: id,
      group: group,
      icon: const IconData(0),
      label: label,
      invoke: (_, __) {},
    );

void main() {
  final entries = [
    _entry('target', CommandGroup.targets, 'NGC 3172 · Polarissima Borealis'),
    _entry('screen', CommandGroup.screens, 'Polar alignment'),
    _entry('setting', CommandGroup.settings, 'Polar alignment stale after'),
  ];

  test('Enter runs the best match, not the first group', () {
    expect(entries[bestCommandIndex(entries, 'polar')].id, 'screen');
  });

  test('among equal matches the first in display order wins', () {
    expect(entries[bestCommandIndex(entries, 'polar alignment')].id, 'screen');
    expect(entries[bestCommandIndex(entries, 'ngc')].id, 'target');
  });
}
