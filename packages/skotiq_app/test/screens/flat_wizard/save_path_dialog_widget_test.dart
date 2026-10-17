import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/save_path_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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

void main() {
  testWidgets('manual path edits immediately update Continue availability',
      (tester) async {
    await pumpAppScreen(tester, const SavePathDialog());

    SkotiqButton continueButton() => tester.widget<SkotiqButton>(
          find.widgetWithText(SkotiqButton, 'Continue'),
        );

    expect(continueButton().onPressed, isNull);

    await tester.enterText(find.byType(TextField), '/data/flats');
    await tester.pump();
    expect(continueButton().onPressed, isNotNull);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(continueButton().onPressed, isNull);
  });

  testWidgets('Browse is single-flight and safe when the dialog closes',
      (tester) async {
    final picked = Completer<String?>();
    var pickerCalls = 0;

    await pumpAppScreen(
      tester,
      const SavePathDialog(),
      extraOverrides: [
        flatWizardSavePathPickerProvider.overrideWithValue(({
          required context,
          required isRemote,
          required currentPath,
        }) {
          pickerCalls++;
          return picked.future;
        }),
      ],
    );

    final browseButton = find.widgetWithText(SkotiqButton, 'Browse...');
    await tester.tap(browseButton);
    await tester.tap(browseButton);
    await tester.pump();

    expect(pickerCalls, 1);
    expect(
      tester.widget<SkotiqButton>(browseButton).isLoading,
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    picked.complete('/data/flats');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('Browse unlocks on host switch and discards the old-host path',
      (tester) async {
    final picked = Completer<String?>();
    final handle = await pumpAppScreen(
      tester,
      const SavePathDialog(),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        flatWizardSavePathPickerProvider.overrideWithValue(({
          required context,
          required isRemote,
          required currentPath,
        }) {
          return picked.future;
        }),
      ],
    );

    final browseButton = find.widgetWithText(SkotiqButton, 'Browse...');
    await tester.tap(browseButton);
    await tester.pump();
    expect(tester.widget<SkotiqButton>(browseButton).isLoading, isTrue);

    final backend = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backend.swap(DisconnectedBackend());
    await tester.pump();
    expect(tester.widget<SkotiqButton>(browseButton).isLoading, isFalse);

    picked.complete('/old-host/flats');
    await tester.pump();
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(tester.takeException(), isNull);
  });
}
