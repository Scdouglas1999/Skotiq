import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/location_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

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

List<Override> _settingsOverrides() => [
      appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
    ];

Future<void> _showImportButton(WidgetTester tester) async {
  final button = find.text('Import .hor / CSV');
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('horizon picker is single-flight and discards an old-host file',
      (tester) async {
    final pick = Completer<XFile?>();
    var pickerCalls = 0;
    var readerCalls = 0;

    final handle = await pumpAppScreen(
      tester,
      const LocationSettingsPage(),
      size: const Size(1280, 1000),
      extraOverrides: [
        ..._settingsOverrides(),
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        horizonImportPickerProvider.overrideWithValue(() {
          pickerCalls++;
          return pick.future;
        }),
        horizonImportReaderProvider.overrideWithValue((file) async {
          readerCalls++;
          return '0 12';
        }),
      ],
    );
    await _showImportButton(tester);

    await tester.tap(find.text('Import .hor / CSV'));
    await tester.tap(find.text('Import .hor / CSV'));
    await tester.pump();

    expect(pickerCalls, 1);
    expect(find.text('Importing horizon...'), findsOneWidget);

    final backendNotifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    await tester.pump();
    expect(find.text('Import .hor / CSV'), findsOneWidget);

    pick.complete(XFile('/old-host.hor'));
    await tester.pump();
    await tester.pump();

    expect(readerCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizon import persists parsed samples and unlocks the button',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const LocationSettingsPage(),
      size: const Size(1280, 1000),
      extraOverrides: [
        ..._settingsOverrides(),
        horizonImportPickerProvider.overrideWithValue(
          () async => XFile('/selected-horizon.csv'),
        ),
        horizonImportReaderProvider.overrideWithValue(
          (file) async => '0,12\n90,7\n',
        ),
      ],
    );
    await _showImportButton(tester);

    await tester.tap(find.text('Import .hor / CSV'));
    // The import button spins while the flow is in flight (including while
    // the confirmation dialog is up), so pumpAndSettle never returns here.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The reduction to eight sectors is confirmed before anything is written.
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final settings = handle.container.read(appSettingsProvider).value!;
    final profile = LegacyHorizonProfile.fromJson(
      settings.horizonProfileJson,
    );
    expect(profile.altitudeAt('N'), 12);
    expect(profile.altitudeAt('E'), 7);
    expect(find.text('Import .hor / CSV'), findsOneWidget);
    expect(
      find.textContaining('Horizon imported from selected-horizon.csv'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizon picker failures are visible and retryable',
      (tester) async {
    var pickerCalls = 0;
    await pumpAppScreen(
      tester,
      const LocationSettingsPage(),
      size: const Size(1280, 1000),
      extraOverrides: [
        ..._settingsOverrides(),
        horizonImportPickerProvider.overrideWithValue(() async {
          pickerCalls++;
          throw StateError('picker unavailable');
        }),
      ],
    );
    await _showImportButton(tester);

    await tester.tap(find.text('Import .hor / CSV'));
    await tester.pump();
    await tester.pump();

    expect(pickerCalls, 1);
    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(find.text('Import .hor / CSV'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
