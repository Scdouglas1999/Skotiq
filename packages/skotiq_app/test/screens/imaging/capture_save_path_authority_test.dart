import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/capture_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwitchingBackendNotifier extends BackendNotifier {
  _SwitchingBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

({ProviderContainer container, _SwitchingBackendNotifier backendNotifier})
    _container({
  required CaptureSavePathPicker picker,
  required CaptureSavePathWriter writer,
}) {
  late _SwitchingBackendNotifier backendNotifier;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) {
        return backendNotifier =
            _SwitchingBackendNotifier(ref, _MockNetworkBackend());
      }),
      captureSavePathPickerProvider.overrideWithValue(picker),
      captureSavePathWriterProvider.overrideWithValue(writer),
    ],
  );
  container.read(backendProvider);
  return (container: container, backendNotifier: backendNotifier);
}

Widget _surface(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => CaptureSavePathButton(
            colors: SkotiqColors.of(context),
            currentPath: '/host-a/captures',
            isRemote: true,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'host switch unlocks the picker and discards the old host selection',
      (tester) async {
    final firstPick = Completer<String?>();
    final secondPick = Completer<String?>();
    var pickCalls = 0;
    final writes = <String>[];
    final h = _container(
      picker: (context, {required isRemote, required initialPath}) {
        expect(isRemote, isTrue);
        expect(initialPath, '/host-a/captures');
        pickCalls++;
        return pickCalls == 1 ? firstPick.future : secondPick.future;
      },
      writer: (path) async => writes.add(path),
    );
    addTearDown(h.container.dispose);

    await tester.pumpWidget(_surface(h.container));
    final browse = find.byType(IconButton);
    expect(find.byTooltip('Choose host capture folder'), findsOneWidget);

    await tester.tap(browse);
    await tester.pump();
    await tester.tap(browse, warnIfMissed: false);
    expect(pickCalls, 1);

    h.backendNotifier.replaceWith(_MockNetworkBackend());
    await tester.pump();

    expect(tester.widget<IconButton>(browse).onPressed, isNotNull);
    firstPick.complete('/host-a/late-selection');
    await tester.pump();
    expect(writes, isEmpty);

    await tester.tap(browse);
    await tester.pump();
    expect(pickCalls, 2);
    secondPick.complete('/host-b/captures');
    await tester.pump();
    await tester.pump();

    expect(writes, ['/host-b/captures']);
  });

  testWidgets('picker failure is visible and the action is retryable',
      (tester) async {
    var pickCalls = 0;
    final writes = <String>[];
    final h = _container(
      picker: (context, {required isRemote, required initialPath}) async {
        pickCalls++;
        if (pickCalls == 1) throw StateError('directory service unavailable');
        return '/host/recovered';
      },
      writer: (path) async => writes.add(path),
    );
    addTearDown(h.container.dispose);

    await tester.pumpWidget(_surface(h.container));
    final browse = find.byType(IconButton);
    expect(find.byTooltip('Choose host capture folder'), findsOneWidget);

    await tester.tap(browse);
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('directory service unavailable'),
      findsOneWidget,
    );
    expect(tester.widget<IconButton>(browse).onPressed, isNotNull);

    await tester.tap(browse);
    await tester.pump();
    await tester.pump();
    expect(writes, ['/host/recovered']);
  });
}
