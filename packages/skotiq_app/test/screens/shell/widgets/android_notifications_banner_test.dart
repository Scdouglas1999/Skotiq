import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/android_notifications_banner.dart';
import 'package:skotiq_app/services/android_alert_permission.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: AndroidNotificationsBanner()),
      ),
    );

void main() {
  testWidgets('says nothing while alerts are allowed', (tester) async {
    await tester.pumpWidget(_host(const []));
    expect(find.textContaining('Alerts are off.', findRichText: true),
        findsNothing);
  });

  testWidgets('Turn on asks, and the offer goes once granted', (tester) async {
    var asked = 0;
    await tester.pumpWidget(
      _host([
        androidNotificationsAuthorizedProvider.overrideWith((_) => false),
        androidNotificationsRequestProvider.overrideWithValue(() async {
          asked++;
          return true;
        }),
      ]),
    );
    expect(find.textContaining('Alerts are off.', findRichText: true),
        findsOneWidget);

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(find.textContaining('Alerts are off.', findRichText: true),
        findsNothing);
  });

  testWidgets('a refusal keeps the offer; closing it hides it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        androidNotificationsAuthorizedProvider.overrideWith((_) => false),
        androidNotificationsRequestProvider.overrideWithValue(
          () async => false,
        ),
      ]),
    );
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Alerts are off.', findRichText: true),
        findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Alerts are off.', findRichText: true),
        findsNothing);
  });
}
