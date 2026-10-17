import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// `sequencerSetSavePath` is the native executor's output directory, while the
/// free-space guard and the disk-space watchdog read
/// `appSettings.imageOutputPath`. Unlinked, the guard watches a different
/// volume than the one being written and reports healthy space on the wrong
/// disk.
class _MockSequencerBackend extends Mock implements SequencerBackend {}

void main() {
  group('POST /api/sequencer/save-path points the disk guard at the same '
      'directory', () {
    late _MockSequencerBackend sequencer;
    late ProviderContainer container;
    late SequencerHandlers handlers;
    late Directory scratch;

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('ns-save-path-test');
      addTearDown(() async {
        if (scratch.existsSync()) await scratch.delete(recursive: true);
      });

      sequencer = _MockSequencerBackend();
      when(
        () => sequencer.sequencerSetSavePath(any()),
      ).thenAnswer((_) async {});

      container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(sequencer)],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Response> setSavePath(String path) => translateHandlerErrors(
      handlers.handleSequencerSetSavePath(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/save-path'),
          body: jsonEncode({'path': path}),
        ),
      ),
    );

    Future<String> outputPath() async {
      await container.read(appSettingsProvider.future);
      return container.read(appSettingsProvider).valueOrNull?.imageOutputPath ??
          '';
    }

    test('the host capture folder follows the executor save path', () async {
      expect(
        await outputPath(),
        isEmpty,
        reason: 'the appliance starts unconfigured, as the rig did',
      );

      final response = await setSavePath(scratch.path);
      expect(response.statusCode, 200);

      verify(() => sequencer.sequencerSetSavePath(scratch.path)).called(1);
      expect(
        await outputPath(),
        scratch.path,
        reason:
            'the free-space guard reads imageOutputPath; leaving it empty is '
            'what let the rig write 30 frames while disk-space reported '
            '"configured": false',
      );
    });

    test('a later change moves both, not one', () async {
      final second = await Directory(
        '${scratch.path}${Platform.pathSeparator}second-volume',
      ).create();

      await setSavePath(scratch.path);
      await setSavePath(second.path);

      verify(() => sequencer.sequencerSetSavePath(second.path)).called(1);
      expect(
        await outputPath(),
        second.path,
        reason:
            'a guard left pointing at the previous directory reports healthy '
            'space on a volume the frames are no longer going to',
      );
    });

    test('a rejected save path changes neither setting', () async {
      // The write probe has to fail for a path the host cannot use. A file
      // where a directory is expected does exactly that on every platform.
      final blocker = File(
        '${scratch.path}${Platform.pathSeparator}not-a-directory',
      );
      await blocker.writeAsString('');

      final response = await setSavePath(blocker.path);

      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['code'], 'save_path_unwritable');
      verifyNever(() => sequencer.sequencerSetSavePath(any()));
      expect(await outputPath(), isEmpty);
    });
  });
}
