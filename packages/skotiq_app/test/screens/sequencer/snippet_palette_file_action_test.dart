import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/snippet_palette.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _DeferredSnippetFileService extends SnippetFileService {
  _DeferredSnippetFileService(this.result);

  final Completer<TemplateSnippet?> result;
  int importCalls = 0;

  @override
  Future<TemplateSnippet?> importSnippet() {
    importCalls++;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('snippet import is single-flight and unlocks after cancellation',
      (tester) async {
    final result = Completer<TemplateSnippet?>();
    final service = _DeferredSnippetFileService(result);

    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SizedBox(
          width: 360,
          height: 800,
          child: SnippetPalette(colors: SkotiqColors.of(context)),
        ),
      ),
      size: const Size(800, 900),
      settle: false,
      extraOverrides: [
        snippetFileServiceProvider.overrideWithValue(service),
      ],
    );

    final importButton = find.byTooltip('Import snippet from file…');
    expect(importButton, findsOneWidget);
    await tester.tap(importButton);
    await tester.tap(importButton);
    await tester.pump();

    expect(service.importCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    result.complete(null);
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byTooltip('Import snippet from file…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
