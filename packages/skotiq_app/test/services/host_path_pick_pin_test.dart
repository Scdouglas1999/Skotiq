// Every screen that asks for a file or folder on the machine that owns the
// data, driven on this computer's backend, a linked host and an unlinked
// client: what reached the system picker, or what the host-path dialog asked.
// Recorded on the code where each screen branched on the link itself.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_settings_panel.dart';
import 'package:skotiq_app/screens/settings/plate_solving_settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/phd2_guiding_settings.dart';
import 'package:skotiq_app/widgets/remote_host_path_dialog.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockPlateSolveService extends Mock implements PlateSolveService {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(phd2Path: '/opt/phd2/bin/phd2');
}

enum _Side { local, linked, unlinked }

SkotiqBackend _backendFor(_Side side) => switch (side) {
      _Side.local => mockBackend(),
      _Side.linked => _MockNetworkBackend(),
      _Side.unlinked => DisconnectedBackend(),
    };

typedef _Site = ({
  String name,
  Widget screen,
  Finder browse,
  List<Override> overrides,
});

List<_Site> _sites() {
  Finder pathBrowse(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(GestureDetector),
      );
  final plate = <Override>[
    plateSolveServiceProvider.overrideWithValue(_MockPlateSolveService()),
    plateSolverDetectionProvider.overrideWith(
      (ref) async => const PlateSolverDetection(),
    ),
    plateSolverPreferenceProvider.overrideWith(
      (ref) async => const PlateSolverPreference(
        astapPath: '/opt/astap/astap',
        catalogPath: '/opt/astap',
        astrometryPath: '/usr/bin/solve-field',
      ),
    ),
    hostAdminAccessProvider.overrideWith((ref) async => true),
  ];
  return [
    for (final type in CalibrationFileType.values)
      (
        name: 'calibration ${type.name}',
        screen: CalibrationFileBrowseButton(
          fileType: type,
          currentPath: '/masters/${type.name}.fits',
        ),
        browse: find.widgetWithText(SkotiqButton, 'Browse'),
        overrides: [
          calibrationFileWriterProvider.overrideWithValue((_, __) async {}),
        ],
      ),
    (
      name: 'plate astap',
      screen: const PlateSolvingSettings(),
      browse: pathBrowse('plate_solver_astap_path'),
      overrides: plate,
    ),
    (
      name: 'plate catalog',
      screen: const PlateSolvingSettings(),
      browse: pathBrowse('plate_solver_catalog_path'),
      overrides: plate,
    ),
    (
      name: 'plate astrometry',
      screen: const PlateSolvingSettings(),
      browse: pathBrowse('plate_solver_astrometry_path'),
      overrides: plate,
    ),
    (
      name: 'phd2',
      screen: const Phd2GuidingSettings(),
      browse: pathBrowse('phd2_executable_path'),
      overrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
        hostAdminAccessProvider.overrideWith((ref) async => true),
      ],
    ),
  ];
}

const _pinned = <String, String>{
  'calibration flat local':
      'openFile {acceptedTypeGroups: [{label: FITS/XISF images, extensions: [fits, fit, fts, xisf], mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: null, multiple: false}',
  'calibration flat linked':
      'dialog Master frame on host | hint C:\\Captures\\master_flat.fits | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use path | clear null | initial /masters/flat.fits',
  'calibration flat unlinked':
      'openFile {acceptedTypeGroups: [{label: FITS/XISF images, extensions: [fits, fit, fts, xisf], mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: null, multiple: false}',
  'calibration bias local':
      'openFile {acceptedTypeGroups: [{label: FITS/XISF images, extensions: [fits, fit, fts, xisf], mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: null, multiple: false}',
  'calibration bias linked':
      'dialog Master frame on host | hint C:\\Captures\\master_flat.fits | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use path | clear null | initial /masters/bias.fits',
  'calibration bias unlinked':
      'openFile {acceptedTypeGroups: [{label: FITS/XISF images, extensions: [fits, fit, fts, xisf], mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: null, multiple: false}',
  'calibration dark local':
      'openFile {acceptedTypeGroups: [{label: FITS/XISF images, extensions: [fits, fit, fts, xisf], mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: null, multiple: false}',
  'calibration dark linked':
      'dialog Master frame on host | hint C:\\Captures\\master_flat.fits | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use path | clear null | initial /masters/dark.fits',
  'calibration dark unlinked':
      'openFile {acceptedTypeGroups: [{label: FITS/XISF images, extensions: [fits, fit, fts, xisf], mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: null, multiple: false}',
  'plate astap local':
      'openFile {acceptedTypeGroups: [{label: ASTAP executable, extensions: null, mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: Use this ASTAP, multiple: false}',
  'plate astap linked':
      'dialog ASTAP executable on imaging host | hint C:\\Program Files\\astap\\astap.exe or /usr/bin/astap | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use host path | clear Use auto-detect | initial /opt/astap/astap',
  'plate astap unlinked':
      'openFile {acceptedTypeGroups: [{label: ASTAP executable, extensions: null, mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: Use this ASTAP, multiple: false}',
  'plate catalog local':
      'getDirectoryPath {initialDirectory: null, confirmButtonText: Use this catalog folder}',
  'plate catalog linked':
      'dialog ASTAP catalog directory on imaging host | hint C:\\Program Files\\astap or /opt/astap | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use host path | clear Use auto-detect | initial /opt/astap',
  'plate catalog unlinked':
      'getDirectoryPath {initialDirectory: null, confirmButtonText: Use this catalog folder}',
  'plate astrometry local':
      'openFile {acceptedTypeGroups: [{label: solve-field, extensions: null, mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: Use this solve-field, multiple: false}',
  'plate astrometry linked':
      'dialog solve-field executable on imaging host | hint /usr/bin/solve-field | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use host path | clear Use auto-detect | initial /usr/bin/solve-field',
  'plate astrometry unlinked':
      'openFile {acceptedTypeGroups: [{label: solve-field, extensions: null, mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: Use this solve-field, multiple: false}',
  'phd2 local':
      'openFile {acceptedTypeGroups: [{label: PHD2 executable, extensions: null, mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: Use this PHD2 executable, multiple: false}',
  'phd2 linked':
      'dialog PHD2 executable on imaging host | hint C:\\Program Files\\PHD2\\PHD2.exe or /usr/bin/phd2 | Enter a path on the imaging computer. Paths on this controlling device are not visible to the host. | submit Use host path | clear Use auto-detect | initial /opt/phd2/bin/phd2',
  'phd2 unlinked':
      'openFile {acceptedTypeGroups: [{label: PHD2 executable, extensions: null, mimeTypes: null, uniformTypeIdentifiers: null, webWildCards: null, macUTIs: null}], initialDirectory: null, confirmButtonText: Use this PHD2 executable, multiple: false}',
};

/// The rows were recorded on Linux. Windows offers `.exe` files for an
/// executable and opens the PHD2 picker in Program Files, macOS in
/// Applications.
String _onThisPlatform(String row) {
  var out = row;
  if (Platform.isWindows) {
    for (final label in [
      'ASTAP executable',
      'solve-field',
      'PHD2 executable'
    ]) {
      out = out.replaceFirst(
        '{label: $label, extensions: null,',
        '{label: $label, extensions: [exe],',
      );
    }
  }
  final phd2Start = Platform.isWindows
      ? r'C:\Program Files'
      : Platform.isMacOS
          ? '/Applications'
          : null;
  if (phd2Start != null && out.contains('Use this PHD2 executable')) {
    out = out.replaceFirst(
      'initialDirectory: null',
      'initialDirectory: $phd2Start',
    );
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const PlateSolverPreference());

  final pickerCalls = <String>[];
  setUp(() {
    pickerCalls.clear();
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      pickerCalls.add('${call.method} ${call.arguments}');
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/file_selector'),
      null,
    );
  });

  for (final site in _sites()) {
    for (final side in _Side.values) {
      final row = '${site.name} ${side.name}';
      testWidgets(row, (tester) async {
        await pumpAppScreen(
          tester,
          site.screen,
          size: const Size(1280, 1400),
          extraOverrides: [
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, _backendFor(side)),
            ),
            ...site.overrides,
          ],
        );
        await tester.tap(site.browse);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final String seen;
        final dialogs = find.byType(RemoteHostPathDialog);
        if (dialogs.evaluate().isNotEmpty) {
          final dialog = tester.widget<RemoteHostPathDialog>(dialogs);
          seen = 'dialog ${dialog.title} | hint ${dialog.hintText} | '
              '${dialog.description} | submit ${dialog.submitLabel} | '
              'clear ${dialog.clearLabel} | initial ${dialog.initialPath}';
          await tester.tap(find.text('Cancel'));
          await tester.pump(const Duration(milliseconds: 300));
        } else {
          expect(pickerCalls, hasLength(1));
          seen = pickerCalls.single;
        }
        expect(seen, _onThisPlatform(_pinned[row]!), reason: row);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
