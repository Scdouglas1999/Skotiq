// The frame strip under the action bar: this session's frames as thumbnails,
// newest at the right and ringed, each with its HFR. A rejected frame is
// dimmed and its HFR is in the error tone. Tapping a frame shows it on the
// stage; tapping it again, or the newest, goes back to the live frame.
//
// Thumbnails come from the backend's sidecar cache by row id, decoded at the
// tile's size; nothing here opens a FITS file.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/frame_thumbnail_loader.dart';
import '../data/session/session_format.dart';
import '../data/session/session_frames_provider.dart';
import '../night_control_contracts.dart';
import 'center_format.dart';
import 'frame_stage.dart';

/// The last finished session, for the strip's line before tonight's run.
@immutable
class NightLastSessionVm {
  const NightLastSessionVm({
    required this.startedAt,
    this.name,
    this.frames,
    this.integrationSecs,
    this.averageHfr,
  });

  final DateTime startedAt;
  final String? name;
  final int? frames;
  final double? integrationSecs;
  final double? averageHfr;

  @override
  bool operator ==(Object other) =>
      other is NightLastSessionVm &&
      other.startedAt == startedAt &&
      other.name == name &&
      other.frames == frames &&
      other.integrationSecs == integrationSecs &&
      other.averageHfr == averageHfr;

  @override
  int get hashCode =>
      Object.hash(startedAt, name, frames, integrationSecs, averageHfr);
}

/// The newest finished session with frames in it, other than the active
/// one; null when there is none. The session table's counters default to
/// zero, so a zero reads as "not recorded" and is left out.
final nightLastSessionProvider = Provider<NightLastSessionVm?>((ref) {
  final sessions = ref.watch(allSessionsProvider).valueOrNull;
  if (sessions == null) return null;
  final activeId = ref.watch(nightSessionIdProvider);
  NightLastSessionVm? last;
  for (final session in sessions) {
    if (session.id == activeId || session.endTime == null) continue;
    if (session.successfulExposures <= 0) continue;
    if (last != null && !session.startTime.isAfter(last.startedAt)) continue;
    final name = session.name?.trim();
    last = NightLastSessionVm(
      startedAt: session.startTime,
      name: name == null || name.isEmpty ? null : name,
      frames: session.successfulExposures,
      integrationSecs: session.totalIntegrationSecs > 0
          ? session.totalIntegrationSecs
          : null,
      averageHfr: session.avgHfr,
    );
  }
  return last;
});

class FrameStrip extends ConsumerStatefulWidget {
  const FrameStrip({super.key});

  static const double height = 70;
  static const double tileWidth = 76;

  @override
  ConsumerState<FrameStrip> createState() => _FrameStripState();
}

class _FrameStripState extends ConsumerState<FrameStrip> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final frames = ref.watch(nightSessionFramesProvider);
    final selected = ref.watch(nightStageSelectionProvider);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.text('nightCtrStripLabel'),
      child: Container(
        height: FrameStrip.height,
        decoration: BoxDecoration(
          color: colors.well,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: frames.isEmpty
            ? const _EmptyStrip()
            : ListView.separated(
                controller: _scroll,
                primary: false,
                // Newest first and reversed, so the strip opens on the newest
                // frame at the right edge and a new frame lands there.
                reverse: true,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceSm,
                  vertical: 5,
                ),
                itemCount: frames.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: SkotiqTokens.spaceSm),
                itemBuilder: (context, index) {
                  final frame = frames[frames.length - 1 - index];
                  return _StripTile(
                    key: ValueKey<int>(frame.id),
                    frame: frame,
                    selected: frame.id == selected,
                    onTap: () => _select(frame),
                  );
                },
              ),
      ),
    );
  }

  void _select(StripFrameVm frame) {
    final selection = ref.read(nightStageSelectionProvider.notifier);
    selection.state =
        frame.isNewest || selection.state == frame.id ? null : frame.id;
  }
}

/// Before tonight's first frame: what lands here, and the last session.
class _EmptyStrip extends ConsumerWidget {
  const _EmptyStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final last = ref.watch(nightLastSessionProvider);
    final summary = last == null ? null : _summary(context, last);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceMd),
      child: Center(
        child: Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(text: l10n.text('nightCtrStripEmpty')),
              if (summary != null)
                TextSpan(
                  text: '   $summary',
                  style: TextStyle(color: colors.textSecondary),
                ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }

  String _summary(BuildContext context, NightLastSessionVm last) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final integration = nightDuration(last.integrationSecs);
    final hfr = last.averageHfr;
    final frames = last.frames;
    final details = <String>[
      if (last.name != null) last.name!,
      if (frames != null)
        l10n.text(
          'nightCtrLastSessionFrames',
          params: <String, String>{'count': '$frames'},
        ),
      if (integration != null) integration,
      if (hfr != null)
        l10n.text(
          'nightCtrHfrValue',
          params: <String, String>{'hfr': hfr.toStringAsFixed(2)},
        ),
    ];
    return l10n.text(
      'nightCtrLastSession',
      params: <String, String>{
        'date': DateFormat.MMMd(locale).format(last.startedAt),
        'details': details.join(' · '),
      },
    );
  }
}

class _StripTile extends ConsumerStatefulWidget {
  const _StripTile({
    super.key,
    required this.frame,
    required this.selected,
    required this.onTap,
  });

  final StripFrameVm frame;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_StripTile> createState() => _StripTileState();
}

class _StripTileState extends ConsumerState<_StripTile> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _StripTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame.id != widget.frame.id) _bytes = _load();
  }

  Future<Uint8List?> _load() =>
      fetchFrameThumbnailBytes(ref, widget.frame.id, source: 'NightStrip');

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final frame = widget.frame;
    final rejected = frame.accepted == false;
    final hfr = frame.hfr;
    final number = frame.frameNumber;
    final ring = widget.selected
        ? colors.textPrimary
        : frame.isNewest
            ? colors.primary
            : null;

    final description = <String>[
      l10n.text(
        'nightCtrStripFrame',
        params: <String, String>{'frame': number == null ? '' : '#$number'},
      ).trim(),
      if (nightFilterExposure(frame.filter, frame.exposureSecs) case final w?)
        w,
      if (hfr != null)
        l10n.text(
          'nightCtrHfrValue',
          params: <String, String>{'hfr': hfr.toStringAsFixed(2)},
        ),
      if (rejected) l10n.text('nightCtrRejected'),
      if (frame.isNewest) l10n.text('nightCtrStripNewest'),
    ].join(', ');

    return Semantics(
      button: true,
      selected: widget.selected,
      label: description,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Tooltip(
        message: description,
        excludeFromSemantics: true,
        waitDuration: SkotiqTokens.durationSlow,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: SkotiqTokens.borderRadiusSm,
          child: SizedBox(
            width: FrameStrip.tileWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: SkotiqTokens.borderRadiusSm,
                      border: ring == null
                          ? null
                          : Border.all(color: ring, width: 2),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Opacity(
                      opacity: rejected ? 0.4 : 1,
                      child: FrameThumbnail(
                        iconSize: 12,
                        bytesFuture: _bytes,
                        fallbackFilePath: frame.filePath ?? nightNoLocalFile,
                        colors: colors,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        number == null ? '' : '#$number',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: SkotiqTypography.captionSm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                    if (hfr != null)
                      Text(
                        nightFixed(hfr, 2),
                        style: SkotiqTypography.withTabular(
                          SkotiqTypography.monoXs.copyWith(
                            color:
                                rejected ? colors.error : colors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
