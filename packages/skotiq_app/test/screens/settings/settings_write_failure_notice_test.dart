// A failed settings write is reported once: by the input that made it, in its
// own bubble, or, when nothing on screen reports it, by the screen's snackbar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import '../../harness/harness.dart';

final _readOnly = StateError(
  'database error: attempt to write a readonly database',
);

class _LoadedAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

/// A settings store that refuses every write, as a read-only database does.
class _ReadOnlySettingsDao extends SettingsDao {
  _ReadOnlySettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async => throw _readOnly;
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

Future<void> _pumpSettings(WidgetTester tester) async {
  _swallowKnownOverflows();
  await pumpAppScreen(
    tester,
    const SettingsScreen(),
    size: const Size(1280, 900),
    extraOverrides: [
      appSettingsProvider.overrideWith(_LoadedAppSettingsNotifier.new),
      settingsDaoProvider.overrideWith(
        (ref) => _ReadOnlySettingsDao(ref.watch(databaseProvider)),
      ),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a switch whose save fails says so once, beside itself', (
    tester,
  ) async {
    await _pumpSettings(tester);

    await tester.tap(find.byType(SettingsSwitch).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('was not saved'), findsOneWidget);
    expect(find.textContaining('Could not save start_minimized'), findsNothing);

    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a failure no input reports reaches the screen\'s snackbar', (
    tester,
  ) async {
    await _pumpSettings(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );

    container.read(appSettingsWriteFailureProvider.notifier).state =
        AppSettingsWriteFailure(
      setting: 'annotation_settings',
      error: _readOnly,
      occurredAt: DateTime.utc(2026, 11, 11),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('Could not save annotation_settings'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
  });
}
