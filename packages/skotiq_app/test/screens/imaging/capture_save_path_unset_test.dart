// An unset capture directory must not become a starting directory.
//
// NamingPattern.baseDir defaults to '.', and the Save Path row already
// renders that as "Not set — choose a folder". The browse button used to hand
// the raw '.' to the picker as initialPath, which on a remote client made the
// host resolve it against the APPLIANCE's process working directory — on a
// systemd Pi, whatever directory the unit started in — and skipped the
// curated "Host roots" listing that /api/files/browse serves when no path is
// supplied. Reproduced live against a paired appliance: the dialog opened in
// the app bundle's install directory with only Parent-folder to climb out.

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

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

ProviderContainer _container({
  required CaptureSavePathPicker picker,
  required CaptureSavePathWriter writer,
}) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
      ),
      captureSavePathPickerProvider.overrideWithValue(picker),
      captureSavePathWriterProvider.overrideWithValue(writer),
    ],
  );
  container.read(backendProvider);
  return container;
}

Widget _surface(ProviderContainer container, String currentPath) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => CaptureSavePathButton(
            colors: SkotiqColors.of(context),
            currentPath: currentPath,
            isRemote: true,
          ),
        ),
      ),
    ),
  );
}

Future<String?> _tapAndCaptureInitialPath(
  WidgetTester tester,
  String currentPath,
) async {
  String? seen;
  var called = false;
  final container = _container(
    picker: (context, {required isRemote, required initialPath}) async {
      seen = initialPath;
      called = true;
      return null;
    },
    writer: (path) async {},
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(_surface(container, currentPath));
  await tester.tap(find.byType(IconButton));
  await tester.pump();
  await tester.pump();

  expect(called, isTrue, reason: 'the picker was never opened');
  return seen;
}

void main() {
  testWidgets('a bare dot is treated as unset, not as a host directory',
      (tester) async {
    expect(await _tapAndCaptureInitialPath(tester, '.'), isNull);
  });

  testWidgets('whitespace around a dot is still unset', (tester) async {
    expect(await _tapAndCaptureInitialPath(tester, '  .  '), isNull);
  });

  testWidgets('an empty path is unset', (tester) async {
    expect(await _tapAndCaptureInitialPath(tester, ''), isNull);
  });

  testWidgets('a real host path is passed through trimmed', (tester) async {
    expect(
      await _tapAndCaptureInitialPath(tester, '  /mnt/captures  '),
      '/mnt/captures',
    );
  });
}
