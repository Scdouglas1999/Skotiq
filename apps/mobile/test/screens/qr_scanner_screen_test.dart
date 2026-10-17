import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/screens/qr_scanner_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  testWidgets('denied camera permission has an in-place retry action', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: const [SkotiqColors.dark]),
        home: QrScannerScreen(
          requestCameraPermission: () async {
            requests++;
            return PermissionStatus.denied;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(requests, 1);
    expect(find.text('Retry camera'), findsOneWidget);
    expect(
      find.textContaining('Camera permission is required'),
      findsOneWidget,
    );
    expect(find.byTooltip('Toggle torch'), findsNothing);

    await tester.tap(find.text('Retry camera'));
    await tester.pumpAndSettle();
    expect(requests, 2);
  });
}
