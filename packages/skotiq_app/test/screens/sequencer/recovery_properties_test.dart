import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/logic_node_properties.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('Recovery action dropdown offers Custom Branch', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: RecoveryProperties(
              colors: SkotiqColors.dark,
              node: RecoveryNode(
                triggerType: TriggerType.hfrDegraded,
                recoveryAction: RecoveryActionType.retry,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButton<RecoveryActionType>));
    await tester.pumpAndSettle();

    expect(find.text('Retry Operation'), findsWidgets);
    expect(find.text('Custom Branch'), findsWidgets);
  });
}
