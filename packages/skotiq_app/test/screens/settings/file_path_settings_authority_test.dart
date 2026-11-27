import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/file_path_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_app/services/host_folders.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

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
    final writes = <(HostPathSetting, String)>[];
    final firstBackend = DisconnectedBackend();

    final handle = await pumpAppScreen(
      tester,
      const SettingsFormScope(
        narrow: false,
        embedded: true,
        child: FilePathSettings(),
      ),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, firstBackend),
        ),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        hostFoldersProvider.overrideWithValue(FakeHostFolders(
          onPick: ({required initialPath}) {
            return pickers[pickerCalls++].future;
          },
        )),
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

    expect(writes, [(HostPathSetting.imageOutput, '/current-host-images')]);
    expect(tester.takeException(), isNull);
  });

  // A headless host has no screen, so a phone linked to it sets the host's
  // sequences folder; the host's settings carry it like the image folder.
  testWidgets('a linked phone sets the host sequences folder', (tester) async {
    final backend = NetworkBackend(
      serverHost: '10.0.0.5',
      serverPort: 8080,
      webSocketPort: 8080,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);
    var pickerCalls = 0;
    final writes = <(HostPathSetting, String)>[];

    await pumpAppScreen(
      tester,
      const SettingsFormScope(
        narrow: false,
        embedded: true,
        child: FilePathSettings(),
      ),
      settle: false,
      extraOverrides: [
        launchRoleProvider.overrideWithValue(LaunchRole.mobile),
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        isRemoteModeProvider.overrideWithValue(true),
        appSettingsProvider.overrideWith(_LoadedAppSettings.new),
        hostFoldersProvider.overrideWithValue(FakeHostFolders(
          onPick: ({required initialPath}) async {
            pickerCalls++;
            return '/host/sequences';
          },
        )),
        filePathSettingsWriterProvider.overrideWithValue(
          (settingKey, path) async => writes.add((settingKey, path)),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    final sequencesBrowse = find.descendant(
      of: find.byType(SettingsPathInput).at(1),
      matching: find.byType(GestureDetector),
    );
    await tester.ensureVisible(sequencesBrowse.first);
    await tester.tap(sequencesBrowse.first);
    await tester.pump();
    await tester.pump();

    expect(find.text('This path can only be changed on the host machine.'),
        findsNothing);
    expect(pickerCalls, 1);
    expect(writes, [(HostPathSetting.sequences, '/host/sequences')]);
  });
}
