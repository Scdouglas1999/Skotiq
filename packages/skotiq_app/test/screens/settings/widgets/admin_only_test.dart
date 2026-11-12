// Owner 2026-11-11: a linked app paired the normal way changes the host's app
// settings. What still needs admin access (credentials, backups, plugins,
// updates) says so on its own row, in plain words, before anyone edits it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/admin_only.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

final _rig = LinkedRig(
  host: '10.0.0.2',
  port: 8080,
  name: 'home',
  tokenScope: 'control',
  pairedAt: DateTime.utc(2026, 11, 11),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool? adminAccess,
  LinkedRig? rig,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hostAdminAccessProvider.overrideWith((ref) async => adminAccess),
        if (rig != null) launchLinkedRigProvider.overrideWithValue(rig),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

const _field = Text('webhook field');

void main() {
  testWidgets('a link without admin access reads where to change it', (
    tester,
  ) async {
    await _pump(
      tester,
      const AdminOnlyControl(child: _field),
      adminAccess: false,
      rig: _rig,
    );
    expect(find.text('webhook field'), findsNothing);
    expect(find.text(adminOnlyAdvice), findsOneWidget);
    expect(find.byKey(const ValueKey('adminOnly.relink')), findsOneWidget);
  });

  testWidgets(
      'a phone, with no link of its own to repair, gets the words '
      'without the button', (tester) async {
    await _pump(
      tester,
      const AdminOnlyControl(child: _field),
      adminAccess: false,
    );
    expect(find.text(adminOnlyAdvice), findsOneWidget);
    expect(find.byKey(const ValueKey('adminOnly.relink')), findsNothing);
  });

  testWidgets('a link with admin access keeps the control', (tester) async {
    await _pump(
      tester,
      const AdminOnlyControl(child: _field),
      adminAccess: true,
      rig: _rig,
    );
    expect(find.text('webhook field'), findsOneWidget);
    expect(find.text(adminOnlyAdvice), findsNothing);
  });

  testWidgets('the imaging computer itself keeps the control', (tester) async {
    await _pump(
      tester,
      const AdminOnlyControl(child: _field),
      adminAccess: null,
    );
    expect(find.text('webhook field'), findsOneWidget);
  });

  testWidgets('an action names itself in its line', (tester) async {
    const text = 'Clear the logs on the imaging computer, or link with admin '
        'access.';
    await _pump(
      tester,
      const AdminOnlyControl(text: text, child: _field),
      adminAccess: false,
    );
    expect(find.text(text), findsOneWidget);
  });

  testWidgets('a whole card says what is kept there, once', (tester) async {
    await _pump(
      tester,
      const AdminOnlyBanner(title: 'Backups are managed there'),
      adminAccess: false,
      rig: _rig,
    );
    expect(find.textContaining('Backups are managed there'), findsOneWidget);
    expect(find.textContaining(adminOnlyAdvice), findsOneWidget);
    expect(find.text('Link with admin access'), findsOneWidget);
  });
}
