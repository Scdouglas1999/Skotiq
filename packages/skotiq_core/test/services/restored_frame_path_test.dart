import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/src/services/restored_frame_path.dart';

/// The sequencer's reject-folder cases (`resolve_reject_dir`, written by
/// `cargo test -p skotiq_sequencer reject_dir_cases`). A restore takes a
/// frame in the reject folder back to the frame folder. An absolute setting
/// inside the frame folder says nothing of which folder that was, so such a
/// frame stays where it is.
void main() {
  final cases =
      (jsonDecode(
                File(
                  '../../test_fixtures/reject_folder/cases.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)['cases']
          as List;

  for (final raw in cases.cast<Map<String, dynamic>>()) {
    final base = raw['base'] as String;
    final setting = raw['setting'] as String?;
    final rejectDir = raw['reject_dir'] as String;
    final namesItsOwnFolder =
        p.isAbsolute(setting?.trim() ?? '') &&
        rejectDir != p.join(base, 'Reject');
    test(
      'a frame rejected into $rejectDir (setting ${jsonEncode(setting)})',
      () {
        expect(
          restoredFramePath(p.join(rejectDir, 'f.fits'), rejectFolder: setting),
          namesItsOwnFolder ? isNull : p.join(base, 'f.fits'),
        );
      },
    );
  }
}
