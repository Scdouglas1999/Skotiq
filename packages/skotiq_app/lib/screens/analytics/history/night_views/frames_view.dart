import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../analytics_providers.dart';
import '../../widgets/image_thumbnail_strip.dart';
import '../night_entry.dart';

/// The Frames of a night: every frame of the session as a graded tile. A tile
/// opens the frame; right-click or long-press rejects or restores it.
class NightFramesView extends ConsumerWidget {
  const NightFramesView(
      {super.key, required this.entry, required this.padding});

  final NightEntry entry;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = entry.session;
    if (session == null) {
      return const EmptyState(
        icon: LucideIcons.image,
        title: 'No frames on record',
        body: 'This run has no session, which is what its frames are filed '
            'under.',
      );
    }
    final colors = SkotiqColors.of(context);
    return ref.watch(dbSessionImagesProvider(session.id)).when(
          loading: () => Padding(
            padding: padding,
            child: const Align(
              alignment: Alignment.topCenter,
              child: ShimmerLoading(
                child: SkotiqPanel(
                  child: SizedBox(height: kAnalyticsThumbnailRailHeight),
                ),
              ),
            ),
          ),
          error: (error, _) => EmptyState.error(
            title: 'Frames did not load',
            body: userFacingError(error),
            onRetry: () => ref.invalidate(dbSessionImagesProvider(session.id)),
          ),
          data: (images) {
            if (images.isEmpty) {
              return const EmptyState(
                icon: LucideIcons.image,
                title: 'No frames were captured',
                body: 'The session ended before its first frame.',
              );
            }
            final lights = images.where((image) => image.isLight).length;
            return Padding(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${context.l10n.text(
                      'analyticsFrameMix',
                      params: {
                        'light': '$lights',
                        'calibration': '${images.length - lights}',
                      },
                    )}. Quality badges are advisory. Right-click or '
                    'long-press a frame to reject or restore it.',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  Expanded(
                    child: ImageThumbnailStrip(images: images, grid: true),
                  ),
                ],
              ),
            );
          },
        );
  }
}
