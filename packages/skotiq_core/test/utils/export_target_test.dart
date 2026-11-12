// The export destination contract.
//
// `file_selector_android` never implements `getSavePath`, so asking
// `file_selector` for a save location on a phone reaches the platform
// interface's base method and throws
// `UnimplementedError: getSavePath() has not been implemented.`, killing the
// export before it writes a byte — on an API 35 emulator, exporting a sequence
// reads "Failed to export: UnimplementedError: getSavePath() has not been
// implemented."
//
// These tests pin both halves: desktop gets the native dialog (including its
// cancel semantics), and no code path may reach `getSaveLocation` on a touch
// platform.
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';

/// Records whether the save dialog was reached, and with what.
class _RecordingFileSelector extends FileSelectorPlatform {
  int getSaveLocationCalls = 0;
  String? lastSuggestedName;
  final String? savePath;

  _RecordingFileSelector({this.savePath});

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    getSaveLocationCalls++;
    lastSuggestedName = options.suggestedName;
    return savePath == null ? null : FileSaveLocation(savePath!);
  }
}

void main() {
  late FileSelectorPlatform original;

  setUp(() => original = FileSelectorPlatform.instance);
  tearDown(() => FileSelectorPlatform.instance = original);

  group('desktop', () {
    test(
      'uses the native save dialog and reports the chosen path',
      () async {
        final selector = _RecordingFileSelector(savePath: '/tmp/chosen.json');
        FileSelectorPlatform.instance = selector;

        final target = await chooseExportTarget(suggestedName: 'M31.skeq.json');

        expect(selector.getSaveLocationCalls, 1);
        expect(selector.lastSuggestedName, 'M31.skeq.json');
        expect(target, isNotNull);
        expect(target!.path, '/tmp/chosen.json');
        // The user picked the location, so it is already reachable.
        expect(target.needsShareSheet, isFalse);
      },
      skip: Platform.isAndroid || Platform.isIOS,
    );

    test(
      'a canceled dialog yields no target',
      () async {
        FileSelectorPlatform.instance = _RecordingFileSelector();

        expect(await chooseExportTarget(suggestedName: 'x.json'), isNull);
      },
      skip: Platform.isAndroid || Platform.isIOS,
    );
  });

  group('touch platforms', () {
    // Forced rather than skipped-unless-on-a-phone: the touch branch is the one
    // that carries the failure, so it is the one CI has to run.
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugIsTouchPlatformOverride = true;
      // path_provider has no Linux-host implementation of the Android channel.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => Directory.systemTemp.path,
          );
    });
    tearDown(() => debugIsTouchPlatformOverride = null);

    // Reaching `getSaveLocation` at all on Android is the failure, because that
    // call is what throws.
    test('never reach the save dialog', () async {
      final selector = _RecordingFileSelector(savePath: '/tmp/unused');
      FileSelectorPlatform.instance = selector;

      final target = await chooseExportTarget(suggestedName: 'M31.skeq.json');

      expect(
        selector.getSaveLocationCalls,
        0,
        reason:
            'getSaveLocation throws UnimplementedError on Android; the '
            'touch branch must resolve a path without it',
      );
      expect(target, isNotNull);
      expect(
        target!.needsShareSheet,
        isTrue,
        reason:
            'the path is inside the app sandbox, so the caller still '
            'has to hand the written file to the share sheet',
      );
      expect(target.path, endsWith('M31.skeq.json'));
    });

    test('a user-authored name cannot escape the export directory', () async {
      FileSelectorPlatform.instance = _RecordingFileSelector();

      final target = await chooseExportTarget(
        suggestedName: '../../etc/passwd',
      );

      expect(target, isNotNull);
      // The separators are gone, so the whole thing is one flat file name
      // sitting in the exports directory rather than a path that climbs out
      // of it.
      expect(File(target!.path).parent.path, endsWith('Skotiq/exports'));
      expect(target.path.split('/').last, isNot(contains('/')));
    });
  });

  group('sanitizeExportFileName', () {
    // Names are frequently user-authored. A sequence called "M31 / Ha" would
    // otherwise be read as a directory and the write would fail with a
    // confusing "no such file or directory".
    test('replaces path separators and reserved characters', () {
      expect(
        sanitizeExportFileName('M31 / Ha (v2).json'),
        'M31 _ Ha (v2).json',
      );
      expect(sanitizeExportFileName(r'a\b:c*d?e"f<g>h|i'), 'a_b_c_d_e_f_g_h_i');
    });

    test('falls back rather than producing an empty name', () {
      expect(sanitizeExportFileName('   '), 'export');
      expect(sanitizeExportFileName('///'), '___');
    });

    test('leaves an ordinary name alone', () {
      expect(
        sanitizeExportFileName('observations_2026-07-25.csv'),
        'observations_2026-07-25.csv',
      );
    });
  });

  group('collapseDoubledExtension', () {
    test('drops a repeated final extension', () {
      expect(collapseDoubledExtension('/a/r_final.png.png'), '/a/r_final.png');
      expect(
        collapseDoubledExtension('/a/m51.skseq.json.json'),
        '/a/m51.skseq.json',
      );
      expect(collapseDoubledExtension('/a/x.FITS.fits'), '/a/x.FITS');
    });

    test('leaves distinct and single extensions alone', () {
      expect(collapseDoubledExtension('/a/m51.skeq.json'), '/a/m51.skeq.json');
      expect(collapseDoubledExtension('/a/r_final.png'), '/a/r_final.png');
      expect(collapseDoubledExtension('/a/notes'), '/a/notes');
      expect(collapseDoubledExtension('/a.b/file'), '/a.b/file');
    });
  });

  // qa-surfaces S24: with no folder given, the save dialog opened in the
  // folder the app was started from (the install folder).
  test('the save dialog opens in the documents folder by default', () async {
    expect(
      await exportInitialDirectory(
        null,
        documents: () async => Directory('/home/me/Documents'),
      ),
      '/home/me/Documents',
    );
    expect(
      await exportInitialDirectory(
        '/srv/plans',
        documents: () async => Directory('/home/me/Documents'),
      ),
      '/srv/plans',
    );
  });
}
