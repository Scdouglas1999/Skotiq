import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/import_sequence_dialog.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

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

class _MockSequenceRepository extends Mock implements SequenceRepository {}

/// A one-target Telescopius export: imports without a catalog lookup.
XFile _telescopiusFile() => XFile.fromData(
      Uint8List.fromList(
        'Pane,Designation,Right Ascension,Declination,Rotation\n'
                '1,M31,0.71,41.27,0\n'
            .codeUnits,
      ),
      name: 'm31.csv',
    );

XFile _memoryFile(String name) {
  return XFile.fromData(Uint8List.fromList(const [123, 125]), name: name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(Sequence.create(name: 'fallback', rootNodeId: 'r'));
  });

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

  testWidgets(
      'an import confirmed after a host switch saves nothing on either host',
      (tester) async {
    final repository = _MockSequenceRepository();
    final results = <bool>[];
    final handle = await pumpAppScreen(
      tester,
      _ImportLauncher(results),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        sequenceImportFilePickerProvider
            .overrideWithValue(() async => _telescopiusFile()),
        sequenceRepositoryProvider.overrideWithValue(repository),
      ],
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('Save to library (do not open)'), findsOneWidget);

    (handle.container.read(backendProvider.notifier)
            as _SwappableBackendNotifier)
        .swap(DisconnectedBackend());
    await tester.pump();
    await tester.tap(find.text('Save to library (do not open)'));
    await tester.pump();
    await tester.tap(find.text('Import').last);
    await tester.pumpAndSettle();

    expect(results, [false]);
    expect(find.textContaining('host changed while importing'), findsOneWidget);
    verifyNever(() => repository.saveSequence(any()));
  });

  testWidgets(
      'a library save the old host finishes after a host switch is reported, '
      'not announced on the new host', (tester) async {
    final repository = _MockSequenceRepository();
    final save = Completer<int>();
    when(() => repository.saveSequence(any())).thenAnswer((_) => save.future);
    final results = <bool>[];
    final handle = await pumpAppScreen(
      tester,
      _ImportLauncher(results),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        sequenceImportFilePickerProvider
            .overrideWithValue(() async => _telescopiusFile()),
        sequenceRepositoryProvider.overrideWithValue(repository),
      ],
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to library (do not open)'));
    await tester.pump();
    await tester.tap(find.text('Import').last);
    await tester.pump();
    verify(() => repository.saveSequence(any())).called(1);

    (handle.container.read(backendProvider.notifier)
            as _SwappableBackendNotifier)
        .swap(DisconnectedBackend());
    await tester.pump();
    save.complete(7);
    await tester.pumpAndSettle();

    expect(results, [true]);
    expect(find.textContaining('saved to the previous host'), findsOneWidget);
    expect(find.textContaining('to library'), findsNothing);
  });
}
