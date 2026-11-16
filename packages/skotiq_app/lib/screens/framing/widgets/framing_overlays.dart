import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';

/// Top left of the framing canvas: what is framed. The name, its catalog id,
/// magnitude and size, its coordinates, then [notes] about the frame (its
/// size and rotation, a mosaic, or that no camera field is set up).
class FramingTargetInfoOverlay extends StatelessWidget {
  final FramingTarget target;
  final List<String> notes;

  const FramingTargetInfoOverlay({
    super.key,
    required this.target,
    this.notes = const [],
  });

  @override
  Widget build(BuildContext context) {
    final details = [
      if (target.catalogId case final id? when id != target.name) id,
      if (target.magnitude case final mag?) 'Mag ${mag.toStringAsFixed(1)}',
      if (target.sizeArcmin case final size?) "${size.toStringAsFixed(0)}'",
    ].join(' · ');
    return Glass(
      child: Builder(
        builder: (context) {
          final colors = context.skotiqColors;
          final secondary =
              SkotiqTypography.caption.copyWith(color: colors.textSecondary);
          Text line(String text, TextStyle style) => Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              );
          // On a canvas too short for every line the lower ones are cut
          // off rather than pushed into the groups below.
          return SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                line(
                  target.name,
                  SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                if (details.isNotEmpty) line(details, secondary),
                line(
                  '${CoordinateFormat.raReadout(target.raHours)}  '
                  '${CoordinateFormat.decReadout(target.decDegrees)}',
                  SkotiqTypography.withTabular(secondary),
                ),
                for (final note in notes)
                  line(
                    note,
                    SkotiqTypography.caption.copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
