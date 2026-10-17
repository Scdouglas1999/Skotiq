import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/notification_toast_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pending exit animation is cancelled when overlay unmounts',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    container.read(uiNotificationProvider.notifier).showInfo(
          'Camera connected',
          duration: const Duration(minutes: 1),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Stack(children: [NotificationToastOverlay()]),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Camera connected'));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(container.read(uiNotificationProvider), hasLength(1));
  });
}
