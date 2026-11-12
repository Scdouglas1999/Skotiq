import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../localization/skotiq_localizations.dart';
import 'app_routes.dart';

/// What a location with no page shows: a stale link, or a route an older or
/// newer build knew. Says so in the app's own words, with the way back.
class RouteNotFoundScreen extends StatelessWidget {
  const RouteNotFoundScreen({super.key, required this.location});

  /// The location that matched nothing, as it was asked for.
  final String location;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ColoredBox(
      color: context.skotiqColors.background,
      child: Center(
        child: EmptyState(
          icon: LucideIcons.compass,
          title: l10n.text('routeNotFoundTitle'),
          body: l10n.text(
            'routeNotFoundBody',
            params: <String, String>{'location': location},
          ),
          action: SkotiqButton(
            label: l10n.text('routeNotFoundBack'),
            icon: LucideIcons.moon,
            variant: ButtonVariant.primary,
            onPressed: () => context.go(AppRoute.tonight.path),
          ),
        ),
      ),
    );
  }
}
