import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/shell/widgets/rig_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

String _basename(String path) => path.split('/').last;

/// These cases pin the English wording, so they resolve against the `en`
/// catalogue the chip now reads from.
final _en = SkotiqLocalizations(const Locale('en'));

void main() {
  group('savePathChipFor', () {
    // Observed: the chip collapsed "not checked yet" into "nothing
    // configured" — `valueOrNull ?? _SavePathStatus(path: '', exists: false)`.
    // Every time the probe re-ran (settings edit, backend swap) the bar flashed
    // the folder-X alarm and "No image output path configured" on a rig whose
    // path was configured and fine. On a remote backend that window is a whole
    // network round-trip.
    test('a probe still in flight says checking, not "no save path"', () {
      final chip = savePathChipFor(
        const AsyncValue<SavePathStatus>.loading(),
        _basename,
        _en,
      );

      expect(chip.tone, SavePathTone.unknown);
      expect(chip.label, 'Checking…');
      expect(chip.tooltip, isNot(contains('No image output path')));
    });

    test('a failed probe reports "could not verify", not "missing"', () {
      final chip = savePathChipFor(
        const AsyncValue<SavePathStatus>.data(
          SavePathStatus(
            path: '/srv/captures',
            existence: SavePathExistence.unknown,
          ),
        ),
        _basename,
        _en,
      );

      expect(chip.tone, SavePathTone.unknown);
      expect(chip.label, 'captures');
      expect(chip.tooltip, contains('Could not verify'));
      expect(chip.tooltip, isNot(contains('is missing')));
    });

    test('a verified path is the only case that reads as fine', () {
      final chip = savePathChipFor(
        const AsyncValue<SavePathStatus>.data(
          SavePathStatus(
            path: '/srv/captures',
            existence: SavePathExistence.present,
          ),
        ),
        _basename,
        _en,
      );

      expect(chip.tone, SavePathTone.ok);
      expect(chip.tooltip, 'Images save to /srv/captures');
    });

    test('a known-missing path still raises the alarm', () {
      final chip = savePathChipFor(
        const AsyncValue<SavePathStatus>.data(
          SavePathStatus(
            path: '/srv/captures',
            existence: SavePathExistence.missing,
          ),
        ),
        _basename,
        _en,
      );

      expect(chip.tone, SavePathTone.alarm);
      expect(chip.tooltip, contains('is missing'));
    });

    test('an unconfigured path still says so plainly', () {
      const chip = AsyncValue<SavePathStatus>.data(
        SavePathStatus(path: '', existence: SavePathExistence.missing),
      );
      final result = savePathChipFor(chip, _basename, _en);

      expect(result.tone, SavePathTone.alarm);
      expect(result.label, 'No save path');
    });

    test('a provider error is surfaced as unknown, not as a missing path', () {
      final chip = savePathChipFor(
        const AsyncValue<SavePathStatus>.error('boom', StackTrace.empty),
        _basename,
        _en,
      );

      expect(chip.tone, SavePathTone.unknown);
      expect(chip.tooltip, contains('Could not read'));
    });
  });

  test('remote save-path status validates the imaging host path', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.validateRemoteDirectory(
        r'Z:\Skotiq\Captures',
        mustExist: true,
        mustBeWritable: false,
      ),
    ).thenAnswer((_) async => const {'valid': true});

    final exists = await configuredSavePathExists(
      backend,
      r'Z:\Skotiq\Captures',
    );

    expect(exists, isTrue);
    verify(
      () => backend.validateRemoteDirectory(
        r'Z:\Skotiq\Captures',
        mustExist: true,
        mustBeWritable: false,
      ),
    ).called(1);
  });
}
