// The command lines the app starts the updater with, against
// test_fixtures/updater_cli/contract.json, which the updater's own argument
// parser reads too (native/skotiq_native/updater/src/main.rs, cli_contract
// tests). The updater ships separately from the app that calls it, so this
// command line and the file layout are a compatibility surface.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

void main() {
  final contract =
      jsonDecode(
            File(
              '../../test_fixtures/updater_cli/contract.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final values = contract['values'] as Map<String, dynamic>;
  final relaunch = (values['relaunch'] as List).cast<String>();
  final relaunchFlags = [for (final a in relaunch) '--relaunch-arg=$a'];

  List<String> expected(String key) => [
    for (final arg in (contract[key] as List).cast<String>())
      arg.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => values[m[1]] as String),
  ];

  test('apply', () {
    expect(
      updaterApplyArguments(
        parentPid: int.parse(values['pid'] as String),
        stagingDir: values['staging'] as String,
        installDir: values['install'] as String,
        backupDir: values['backup'] as String,
        pendingFile: values['pending'] as String,
        expectedHashesFile: values['hashes'] as String,
        relaunchFlags: relaunchFlags,
      ),
      expected('apply'),
    );
  });

  test('rollback', () {
    expect(
      updaterRollbackArguments(
        parentPid: int.parse(values['pid'] as String),
        installDir: values['install'] as String,
        backupDir: values['backup'] as String,
        pendingFile: values['pending'] as String,
        relaunchFlags: relaunchFlags,
      ),
      expected('rollback'),
    );
  }, testOn: '!windows');

  test('the restore point the app looks for', () {
    final layout = contract['layout'] as Map<String, dynamic>;
    expect(updaterRollbackLogFile, layout['rollbackLogFile']);
  });
}
