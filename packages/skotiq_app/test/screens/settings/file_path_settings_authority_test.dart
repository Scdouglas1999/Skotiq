import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/file_path_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _LoadedAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        imageOutputPath: '/images',
        sequencesPath: '/sequences',
      );
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host change discards selected path and unlocks a fresh browse',
      (tester) async {
    final pickers = <Completer<String?>>[
      Completer<String?>(),
      Completer<String?>(),
    ];
    var pickerCalls = 0;
    final writes = <(String, String)>[];
    final firstBackend = DisconnectedBackend();

    final handle = await pumpAppScreen(
      tester,
      const FilePathSettings(embedded: true),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, firstBackend),
        ),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        filePathSettingsPickerProvider.overrideWithValue(
          (context, {required isRemote, required currentPath}) {
            return pickers[pickerCalls++].future;
          },
        ),
        filePathSettingsWriterProvider.overrideWithValue(
          (settingKey, path) async => writes.add((settingKey, path)),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    final imagePathInput = find.byType(SettingsPathInput).first;
    final browseButton = find.descendant(
      of: imagePathInput,
      matching: find.byType(GestureDetector),
    );

    await tester.tap(browseButton);
    await tester.pump();
    expect(pickerCalls, 1);
    expect(
      find.descendant(
        of: imagePathInput,
        matching: find.byType(SkotiqSpinner),
      ),
      findsOneWidget,
    );

    final notifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    notifier.swap(DisconnectedBackend());
    await tester.pump();
    expect(
      find.descendant(
        of: imagePathInput,
        matching: find.byType(SkotiqSpinner),
      ),
      findsNothing,
    );

    pickers.first.complete('/old-host-images');
    await tester.pump();
    await tester.pump();

    expect(writes, isEmpty);
    expect(find.textContaining('host changed'), findsOneWidget);

    await tester.tap(browseButton);
    await tester.pump();
    expect(pickerCalls, 2);

    pickers[1].complete('/current-host-images');
    await tester.pump();
    await tester.pump();

    expect(writes, [('image', '/current-host-images')]);
    expect(tester.takeException(), isNull);
  });
}
