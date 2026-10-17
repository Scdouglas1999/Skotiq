import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/exported_file_reveal.dart';

void main() {
  // These run on the Linux test host, which takes the DESKTOP branch
  // (path snackbar). The mobile branch (share sheet) needs a platform channel
  // and is exercised on-device; here we lock the desktop contract that six
  // export call-sites depend on.
  testWidgets('desktop: shows the default path snackbar', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    await revealExportedFile(ctx, '/tmp/skotiq/export.csv');
    await tester.pump();

    expect(find.textContaining('/tmp/skotiq/export.csv'), findsOneWidget);
    expect(find.textContaining('Exported to'), findsOneWidget);
  }, skip: Platform.isAndroid || Platform.isIOS);

  testWidgets('desktop: honours a custom desktopMessage', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    await revealExportedFile(
      ctx,
      '/tmp/logs.txt',
      desktopMessage: 'Logs exported to: /tmp/logs.txt',
    );
    await tester.pump();

    expect(find.text('Logs exported to: /tmp/logs.txt'), findsOneWidget);
  }, skip: Platform.isAndroid || Platform.isIOS);
}
