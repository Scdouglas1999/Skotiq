// The two toast surfaces must agree about what they may paint over.
//
// The contextual tour nudge declares a TransientBottomInset and the SnackBar
// path honours it, so on Equipment the snackbar clears the nudge card entirely.
// A NotificationToastOverlay with a hardcoded `bottom: 56` does not: on the
// Dashboard the refusal raised by clicking the disabled Edit Dashboard paints a
// card at y 565-641 straight over the nudge card at y 578-670, covering its
// title and body.
//
// One declaration, two consumers, one behaviour: the overlay reads the same
// notifier the snackbar helper reads.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/transient_bottom_inset.dart';
import 'package:skotiq_app/widgets/notification_toast_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<ProviderContainer> _pumpOverlay(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  container.read(uiNotificationProvider.notifier).showError(
        'Connect a device first',
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
  return container;
}

/// Bottom of the window minus the toast card's bottom edge.
double _gapBelowToast(WidgetTester tester) {
  final toast = tester.getRect(find.text('Connect a device first'));
  final screen = tester.getRect(find.byType(Scaffold));
  return screen.bottom - toast.bottom;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TransientBottomInset.currentInset.value = 0);

  testWidgets('with nothing declared the toast keeps its usual place', (
    tester,
  ) async {
    await _pumpOverlay(tester);
    expect(_gapBelowToast(tester), greaterThan(50));
    expect(_gapBelowToast(tester), lessThan(120));
  });

  testWidgets('a declared bottom inset lifts the toast clear of it', (
    tester,
  ) async {
    await _pumpOverlay(tester);
    final before = _gapBelowToast(tester);

    // What the tour nudge publishes while its card is on screen.
    TransientBottomInset.currentInset.value = 240;
    await tester.pump();

    final after = _gapBelowToast(tester);
    expect(
      after,
      greaterThanOrEqualTo(240),
      reason: 'the toast must clear the card that declared the inset',
    );
    expect(after, greaterThan(before));
  });

  testWidgets('the lift is released when the declaring card goes away', (
    tester,
  ) async {
    await _pumpOverlay(tester);
    TransientBottomInset.currentInset.value = 240;
    await tester.pump();
    expect(_gapBelowToast(tester), greaterThanOrEqualTo(240));

    TransientBottomInset.currentInset.value = 0;
    await tester.pump();
    expect(_gapBelowToast(tester), lessThan(120));
  });
}
