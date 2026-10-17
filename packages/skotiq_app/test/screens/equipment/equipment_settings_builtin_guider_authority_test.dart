import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/tabs/settings_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

BuiltinGuiderConfig _config({required int gain}) =>
    BuiltinGuiderConfig.defaults.copyWith(gain: gain);

TextField _gainField(WidgetTester tester) => tester.widget<TextField>(
      find.byKey(const ValueKey('builtin-guider-gain')),
    );

Future<void> _pumpFrames(WidgetTester tester, [int count = 4]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(BuiltinGuiderConfig.defaults);
  });

  testWidgets('host switch rejects a late config load from the previous host',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    final hostALoad = Completer<BuiltinGuiderConfig>();
    when(hostA.builtinGuiderGetConfig).thenAnswer((_) => hostALoad.future);
    when(hostB.builtinGuiderGetConfig)
        .thenAnswer((_) async => _config(gain: 222));

    late _SwappableBackendNotifier backendNotifier;
    await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
      settle: false,
    );
    await _pumpFrames(tester);

    backendNotifier.switchTo(hostB);
    await _pumpFrames(tester);
    expect(_gainField(tester).controller!.text, '222');

    hostALoad.complete(_config(gain: 111));
    await _pumpFrames(tester);

    expect(_gainField(tester).controller!.text, '222');
    expect(find.textContaining('gain 222'), findsOneWidget);
  });

  testWidgets('late apply completion cannot overwrite the replacement host',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    final hostAWrite = Completer<void>();
    when(hostA.builtinGuiderGetConfig)
        .thenAnswer((_) async => _config(gain: 111));
    when(() => hostA.builtinGuiderSetConfig(any()))
        .thenAnswer((_) => hostAWrite.future);
    when(hostB.builtinGuiderGetConfig)
        .thenAnswer((_) async => _config(gain: 222));

    late _SwappableBackendNotifier backendNotifier;
    await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
      settle: false,
    );
    await _pumpFrames(tester);

    await tester.enterText(
      find.byKey(const ValueKey('builtin-guider-gain')),
      '333',
    );
    // Apply is disabled until something is actually pending, and `enterText`
    // does not pump — so the button needs a frame to pick the edit up.
    await tester.pump();
    final apply = find.byKey(const ValueKey('builtin-guider-apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pump();
    verify(() => hostA.builtinGuiderSetConfig(any())).called(1);

    backendNotifier.switchTo(hostB);
    await _pumpFrames(tester);
    expect(_gainField(tester).controller!.text, '222');

    hostAWrite.complete();
    await _pumpFrames(tester);

    expect(_gainField(tester).controller!.text, '222');
    expect(find.textContaining('gain 222'), findsOneWidget);
    verifyNever(() => hostB.builtinGuiderSetConfig(any()));
  });

  testWidgets('failed reset preserves the loaded values', (tester) async {
    final backend = mockBackend();
    when(backend.builtinGuiderGetConfig)
        .thenAnswer((_) async => _config(gain: 321));
    when(() => backend.builtinGuiderSetConfig(any())).thenAnswer(
      (_) async => throw StateError('write failed'),
    );

    await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      backend: backend,
      settle: false,
    );
    await _pumpFrames(tester);
    expect(_gainField(tester).controller!.text, '321');

    final reset = find.byKey(const ValueKey('builtin-guider-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await _pumpFrames(tester);

    expect(_gainField(tester).controller!.text, '321');
    expect(find.textContaining('gain 321'), findsOneWidget);
    expect(find.textContaining('Failed to reset settings'), findsOneWidget);
  });
}
