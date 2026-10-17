import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
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

class _TestOnboardingNotifier extends OnboardingNotifier {
  _TestOnboardingNotifier(super.ref);
}

({ProviderContainer container, _SwitchingBackendNotifier backendNotifier})
    _container({
  required OnboardingCaptureDirectoryPicker picker,
  required OnboardingCaptureDirectoryWriter writer,
}) {
  late _SwitchingBackendNotifier backendNotifier;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) {
        return backendNotifier =
            _SwitchingBackendNotifier(ref, _MockNetworkBackend());
      }),
      onboardingDraftProvider.overrideWith(_TestOnboardingNotifier.new),
      onboardingCaptureDirectoryPickerProvider.overrideWithValue(picker),
      onboardingCaptureDirectoryWriterProvider.overrideWithValue(writer),
    ],
  );
  container.read(backendProvider);
  return (container: container, backendNotifier: backendNotifier);
}

Widget _surface(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: OnboardingCaptureDirStep()),
    ),
  );
}

void main() {
  testWidgets(
      'host switch unlocks Browse and discards the prior host directory',
      (tester) async {
    final first = Completer<String?>();
    final second = Completer<String?>();
    var pickerCalls = 0;
    final writes = <String>[];
    final h = _container(
      picker: (context, {required isRemote, required initialPath}) {
        expect(isRemote, isTrue);
        pickerCalls++;
        return pickerCalls == 1 ? first.future : second.future;
      },
      writer: (path) async => writes.add(path),
    );
    addTearDown(h.container.dispose);

    await tester.pumpWidget(_surface(h.container));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();

    expect(find.text('Waiting for folder selection…'), findsOneWidget);
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Browse'),
          )
          .onPressed,
      isNull,
    );

    h.backendNotifier.replaceWith(_MockNetworkBackend());
    await tester.pump();
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Browse'),
          )
          .onPressed,
      isNotNull,
    );

    first.complete('/host-a/captures');
    await tester.pump();
    expect(writes, isEmpty);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();
    second.complete('/host-b/captures');
    await tester.pump();
    await tester.pump();

    expect(writes, ['/host-b/captures']);
  });

  testWidgets('closing the step while the picker is open is safe',
      (tester) async {
    final picker = Completer<String?>();
    final h = _container(
      picker: (context, {required isRemote, required initialPath}) =>
          picker.future,
      writer: (path) async {},
    );
    addTearDown(h.container.dispose);

    await tester.pumpWidget(_surface(h.container));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    picker.complete('/late/path');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
