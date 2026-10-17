// "Refine in Darkroom" must exist on BOTH header arms.
//
// The header collapses into a popup menu below ~430px because the inline row
// overflows there; a control added to only one arm is invisible on exactly the
// device the morning notification is tapped on. Both arms also need the same
// gate: the Darkroom renders from the night's LINEAR master, which is reached
// through the session, so a standalone stack with no session row has nothing to
// refine.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/stack_result/stack_result_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

StackAndShareResult _result({int? sessionId}) => StackAndShareResult(
      id: 21,
      targetName: 'Veil',
      sessionId: sessionId,
      framesStacked: 12,
      framesAttempted: 12,
      integrationSecs: 1440,
      avgAlignmentResidual: 0.4,
      width: 2,
      height: 2,
      channels: 1,
      createdAt: DateTime.utc(2026, 8, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    required StackAndShareResult result,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          stackResultViewerProvider(
            result.id!,
          ).overrideWith((ref) async => result),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: StackResultScreen(resultId: result.id!),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('the wide arm', () {
    testWidgets('offers the control for a stack with a session', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1400, 1000),
        result: _result(sessionId: 3),
      );

      final button = find.byKey(
        const ValueKey('stack_result_refine_in_darkroom'),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<SkotiqButton>(button).onPressed, isNotNull);
    });

    testWidgets('disables it for a standalone stack and says why', (
      tester,
    ) async {
      await pump(tester, size: const Size(1400, 1000), result: _result());

      final button = find.byKey(
        const ValueKey('stack_result_refine_in_darkroom'),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<SkotiqButton>(button).onPressed, isNull);

      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: button, matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, contains('no imaging session'));
    });
  });

  group('the phone arm', () {
    testWidgets('carries the same entry in the overflow menu', (tester) async {
      await pump(
        tester,
        size: const Size(430, 932),
        result: _result(sessionId: 3),
      );

      // The inline row is gone at phone width; the entry lives in the menu.
      expect(
        find.byKey(const ValueKey('stack_result_refine_in_darkroom')),
        findsNothing,
      );
      expect(find.byType(PopupMenuButton<Object?>), findsNothing);

      await tester.tap(find.byIcon(SkotiqIcons.share).first);
      await tester.pumpAndSettle();

      expect(find.text('Refine in Darkroom'), findsOneWidget);
    });

    testWidgets('names the reason in the menu for a standalone stack', (
      tester,
    ) async {
      await pump(tester, size: const Size(430, 932), result: _result());

      await tester.tap(find.byIcon(SkotiqIcons.share).first);
      await tester.pumpAndSettle();

      expect(find.text('Refine in Darkroom'), findsOneWidget);
      expect(
        find.text('No imaging session, so no linear master'),
        findsOneWidget,
        reason: 'a popup item has no tooltip; the reason must be in the row',
      );
    });
  });
}
