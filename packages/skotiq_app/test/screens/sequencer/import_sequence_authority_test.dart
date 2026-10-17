import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/import_sequence_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _ImportLauncher extends ConsumerWidget {
  final List<bool> results;

  const _ImportLauncher(this.results);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () async {
        results.add(await ImportSequenceFlow.run(context, ref));
      },
      child: const Text('Import'),
    );
  }
}

XFile _memoryFile(String name) {
  return XFile.fromData(Uint8List.fromList(const [123, 125]), name: name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sequence import is single-flight and rejects an old-host file',
      (tester) async {
    final picker = Completer<XFile?>();
    var pickerCalls = 0;
    final results = <bool>[];
    final handle = await pumpAppScreen(
      tester,
      _ImportLauncher(results),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        sequenceImportFilePickerProvider.overrideWithValue(() {
          pickerCalls++;
          return picker.future;
        }),
      ],
    );

    await tester.tap(find.text('Import'));
    await tester.tap(find.text('Import'));
    await tester.pump();
    expect(pickerCalls, 1);

    final backendNotifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    picker.complete(_memoryFile('old-host-sequence.json'));
    await tester.pump();
    await tester.pump();

    expect(results, hasLength(2));
    expect(results, everyElement(isFalse));
    expect(find.textContaining('host changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sequence picker completion after launcher disposal is safe',
      (tester) async {
    final picker = Completer<XFile?>();
    final results = <bool>[];
    await pumpAppScreen(
      tester,
      _ImportLauncher(results),
      extraOverrides: [
        sequenceImportFilePickerProvider.overrideWithValue(() => picker.future),
      ],
    );

    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    picker.complete(_memoryFile('late-sequence.json'));
    await tester.pump();
    await tester.pump();

    expect(results, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sequence picker failures are surfaced and release the flow',
      (tester) async {
    final results = <bool>[];
    var calls = 0;
    await pumpAppScreen(
      tester,
      _ImportLauncher(results),
      extraOverrides: [
        sequenceImportFilePickerProvider.overrideWithValue(() async {
          calls++;
          throw StateError('picker unavailable');
        }),
      ],
    );

    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump();

    expect(calls, 2);
    expect(results, [false, false]);
    expect(find.textContaining('picker unavailable'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
