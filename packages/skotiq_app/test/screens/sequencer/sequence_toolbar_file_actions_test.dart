import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';
import 'canvas_bar_menu.dart';

class _DeferredSequenceFileService extends SequenceFileService {
  final importResult = Completer<Sequence?>();
  int importCalls = 0;

  @override
  Future<Sequence?> importSequence() {
    importCalls++;
    return importResult.future;
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'open sequence is single-flight and cannot mutate a different host',
    (tester) async {
      final hostA = mockBackend();
      final hostB = mockBackend();
      final fileService = _DeferredSequenceFileService();
      late _SwappableBackendNotifier backendNotifier;

      final handle = await pumpAppScreen(
        tester,
        Builder(
          builder: (context) => SequenceToolbar(
            colors: SkotiqColors.of(context),
          ),
        ),
        size: const Size(1600, 900),
        extraOverrides: [
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
          sequenceFileServiceProvider.overrideWithValue(fileService),
        ],
      );

      await tapCanvasBarAction(tester, 'Open sequence');
      await tester.pump();
      expect(fileService.importCalls, 1);

      // The same action is visibly disabled while the native picker is open.
      await tapCanvasBarAction(tester, 'Open sequence');
      await tester.pump();
      expect(fileService.importCalls, 1);

      backendNotifier.switchTo(hostB);
      fileService.importResult.complete(Sequence.create(name: 'Host A file'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(handle.container.read(currentSequenceProvider), isNull);
      expect(
        find.textContaining('imaging host changed while the file dialog'),
        findsOneWidget,
      );
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
