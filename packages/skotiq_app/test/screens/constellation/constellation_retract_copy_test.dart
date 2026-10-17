import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Wave-2 update: a real, reachable Retract action now lands. The detail screen
/// renders the persisted contribution receipts (`myContributionsProvider`) with
/// a per-row Retract wired to `ConstellationService.retractTile`, so the
/// twice-printed "subtract your contribution exactly" promise is now backed by a
/// button. This test guards that the action — not just the copy — is present,
/// and that the contribute consent still explains the additive-sums protection.
void main() {
  const detailScreen =
      'lib/screens/constellation/shared_target_detail_screen.dart';
  const contributeSheet =
      'lib/screens/constellation/constellation_contribute_sheet.dart';

  String read(String relative) {
    final file = File(relative);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected $relative relative to the package root (run from '
          'packages/skotiq_app)',
    );
    return file.readAsStringSync();
  }

  test('detail screen wires a real retract action to the service', () {
    final source = read(detailScreen);
    // The promise is now backed by a reachable action, not just copy.
    expect(
      source.contains('retractTile'),
      isTrue,
      reason: 'the detail screen must call ConstellationService.retractTile so '
          'the "subtract your contribution exactly" promise is reachable.',
    );
    expect(source.contains('myContributionsProvider'), isTrue);
    expect(source.contains('Retract'), isTrue);
  });

  test('contribute consent copy still explains the additive-sums protection',
      () {
    final source = read(contributeSheet);
    expect(source, contains('additive co-add sums'));
    expect(source, contains('subtracted exactly'));
  });
}
