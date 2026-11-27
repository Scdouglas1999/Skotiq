import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/app_frame.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/widgets/red_night_filter.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The themed app for what the phone shows outside the shell: the connection
/// screen and first-run setup.
class PhoneStandaloneApp extends ConsumerWidget {
  const PhoneStandaloneApp({super.key, required this.home, this.navigatorKey});

  final Widget home;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final theme = resolveSkotiqThemeData(
      themeSetting: settings?.theme ?? 'dark',
      accentColorHex: settings?.accentColor,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiOverlayStyleFor(theme),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Skotiq',
        debugShowCheckedModeBanner: false,
        theme: theme,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        builder: (context, child) => UnfocusOnKeyboardClose(
          child: RedNightScreen(child: child ?? const SizedBox.shrink()),
        ),
        navigatorObservers: skotiqNavigatorObservers(),
        home: home,
      ),
    );
  }
}
