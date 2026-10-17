import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The "Session frames" tab: every frame this run has captured, newest first.
///
/// It reads the SAME provider the Tonight thumbnail strip reads
/// (`recentSessionFramesProvider`) — no new data, no second source of truth for
/// what the session holds.
class ImagingSessionFrames extends ConsumerWidget {
  const ImagingSessionFrames({super.key, this.onFrameSelected});

  /// Puts the tapped frame back on the canvas.
  final ValueChanged<CapturedImage>? onFrameSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frames = ref.watch(recentSessionFramesProvider);

    if (frames.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'No frames yet',
          body: 'Frames appear here as the session captures them.',
        ),
      );
    }

    // Newest first: the frame an operator wants is the one that just landed.
    final ordered = frames.reversed.toList(growable: false);

    return Padding(
      padding: SkotiqTokens.paddingLg,
      child: SkotiqPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHead(
              label: 'Session frames',
              icon: SkotiqIcons.image,
              trailing: [SkotiqChip(label: '${ordered.length}')],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Expanded(
              child: ListView.builder(
                itemCount: ordered.length,
                itemBuilder: (context, index) {
                  final frame = ordered[index];
                  return ListRow(
                    icon: SkotiqIcons.image,
                    title: _frameTitle(frame),
                    trailing: _timeLabel(frame.capturedAt),
                    showDivider: index < ordered.length - 1,
                    onTap: onFrameSelected == null
                        ? null
                        : () => onFrameSelected!(frame),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _frameTitle(CapturedImage frame) {
    final filter = frame.settings.filter;
    final exposure = frame.settings.exposureTime;
    final exposureLabel = exposure >= 1
        ? '${exposure.toStringAsFixed(0)} s'
        : '${exposure.toStringAsFixed(1)} s';
    final parts = <String>[
      frame.settings.frameType.displayName,
      exposureLabel,
      if (filter != null && filter.isNotEmpty) filter,
      if (frame.stats?.hfr != null)
        'HFR ${frame.stats!.hfr!.toStringAsFixed(2)} px',
      if (frame.stats?.starCount != null) '${frame.stats!.starCount} stars',
    ];
    return parts.join(' · ');
  }

  static String _timeLabel(DateTime capturedAt) {
    final local = capturedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
