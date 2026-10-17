import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../localization/skotiq_localizations.dart';
import 'work_locally.dart';

/// Full-width banner shown while no backend is installed.
///
/// Desktop can restore its local backend directly; client-only platforms do
/// not offer that action.
class DisconnectedBackendBanner extends ConsumerWidget {
  const DisconnectedBackendBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(sequencerBackendProvider) is! DisconnectedBackend) {
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    return Material(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.text('disconnectedBanner'),
                textAlign: canWorkLocally ? TextAlign.start : TextAlign.center,
                style: SkotiqTypography.labelQuiet.copyWith(
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (canWorkLocally)
              const WorkLocallyButton(
                variant: ButtonVariant.destructive,
              ),
          ],
        ),
      ),
    );
  }
}
