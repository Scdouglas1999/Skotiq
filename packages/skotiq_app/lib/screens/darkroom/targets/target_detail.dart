import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../build_masters/job_views.dart' show describeEta;
import 'calibration_panel.dart';
import 'darkroom_image.dart';
import 'darkroom_targets_model.dart';
import 'darkroom_targets_providers.dart';
import 'nights_strip.dart';

const double _heroHeight = 292;

/// The hero image is drawn this much wider than the card, centered at this
/// fraction of its width.
const double _heroImageScale = 1.25;
const double _heroImageCenter = .64;
const double _heroImageCenterAlone = .7;
const double _tileWidth = 92;
const double _tileThumb = 78;

/// The detail is at least this wide before the channel tiles sit inside the
/// hero card instead of under it.
const double _tilesInHeroWidth = 1100;

/// The detail is at least this wide before Calibration and Last masters sit
/// side by side.
const double _sideBySideWidth = 1180;

/// One target: its hero image and channels, every night sub by sub, the
/// calibration it will use and the masters it has.
class DarkroomTargetDetail extends ConsumerWidget {
  const DarkroomTargetDetail({super.key, required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(darkroomBuildJobsProvider);
    final ownJob = job != null && job.target == target.key ? job : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _sideBySideWidth;
        final tilesInHero = constraints.maxWidth >= _tilesInHeroWidth &&
            target.channels.length <= 5;
        return ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.space2xl,
            vertical: SkotiqTokens.spaceXl,
          ),
          children: [
            if (ownJob != null) ...[
              _JobBanner(job: ownJob),
              const SizedBox(height: SkotiqTokens.spaceLg),
            ],
            _Hero(target: target, job: job, tilesInHero: tilesInHero),
            if (!tilesInHero) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _ChannelTiles(target: target),
              ),
            ],
            const SizedBox(height: SkotiqTokens.spaceLg),
            DarkroomTargetPanel(
              key: const ValueKey('darkroom_nights_panel'),
              title: 'Nights',
              subtitle: 'every sub as it was taken · noon to noon',
              trailing: _Legend(target: target),
              stackHeaderBelow: 1100,
              child: target.nights.isEmpty
                  ? Text(
                      'No lights captured yet.',
                      style: SkotiqTypography.bodySm.copyWith(
                        color: context.skotiqColors.textSecondary,
                      ),
                    )
                  : DarkroomNightsStrip(nights: target.nights),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: DarkroomCalibrationPanel(target: target),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  Expanded(flex: 2, child: _LastMasters(target: target)),
                ],
              )
            else ...[
              DarkroomCalibrationPanel(target: target),
              const SizedBox(height: SkotiqTokens.spaceLg),
              _LastMasters(target: target),
            ],
          ],
        );
      },
    );
  }
}

/// The sentence under the target's name.
String darkroomHeroSentence(DarkroomTarget target, DarkroomBuildJob? job) {
  if (job != null && job.target == target.key && job.active) {
    return job.stage == DarkroomJobStage.framing
        ? 'Checking the framing of every sub.'
        : 'Building masters now: ${job.overallDone} of ${job.overallTotal} '
            'subs.';
  }
  final nights = target.nights.where((n) => n.kept > 0).length;
  if (nights == 0) return 'No kept subs yet.';
  if (target.masters.isEmpty) {
    return '$nights night${nights == 1 ? '' : 's'} of kept subs, '
        'no masters yet.';
  }
  final fresh = target.newNights;
  final more = target.newSubsInBuiltNights;
  final topUp = target.nights
      .where((n) => n.use == DarkroomNightUse.partly)
      .map((n) => darkroomShortDate(n.evening))
      .join(', ');
  if (fresh > 0 && more > 0) {
    return '$fresh new night${fresh == 1 ? '' : 's'} since your last '
        'masters, and $more more subs from $topUp.';
  }
  if (fresh > 0) {
    return '$fresh new night${fresh == 1 ? '' : 's'} since your last '
        'masters, ready to fold in.';
  }
  if (more > 0) {
    return '$more subs from $topUp are not in your masters yet.';
  }
  return 'No new subs since your last masters.';
}

/// `GALAXY · AND · RA 02h 22m 33s · DEC +42° 20' 57"`.
String darkroomHeroOverline(DarkroomTarget target) {
  final row = target.row;
  String hms(double hours) {
    final total = (hours * 3600).round();
    return '${two(total ~/ 3600 % 24)}h ${two(total ~/ 60 % 60)}m '
        '${two(total % 60)}s';
  }

  String dms(double deg) {
    final total = (deg.abs() * 3600).round();
    return '${deg < 0 ? '-' : '+'}${two(total ~/ 3600)}° '
        "${two(total ~/ 60 % 60)}' ${two(total % 60)}\"";
  }

  return [
    if (row?.objectType?.trim().isNotEmpty == true)
      row!.objectType!.trim().toUpperCase(),
    if (row?.constellation?.trim().isNotEmpty == true)
      row!.constellation!.trim().toUpperCase(),
    if (row != null) 'RA ${hms(row.ra)}',
    if (row != null) 'DEC ${dms(row.dec)}',
    if (row == null) darkroomFilterNames(target),
  ].join(' · ');
}

String darkroomFilterNames(DarkroomTarget target) =>
    target.filters.every((f) => f.length == 1)
        ? target.filters.join()
        : target.filters.join(' ');

class _Hero extends ConsumerWidget {
  const _Hero({
    required this.target,
    required this.job,
    required this.tilesInHero,
  });

  final DarkroomTarget target;
  final DarkroomBuildJob? job;
  final bool tilesInHero;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final hero = target.heroMaster;
    final color = target.color;
    final otherBusy = job != null && job!.active && job!.target != target.key;
    final hasKept = target.nights.any((n) => n.kept > 0);
    final ownBusy = job != null && job!.active && job!.target == target.key;
    final buildReason = !hasKept
        ? 'There are no kept subs to build from.'
        : ownBusy
            ? 'This target is being built now.'
            : (otherBusy
                ? 'A build for ${job!.target} is running. One build runs at '
                    'a time.'
                : null);
    final open = color ?? hero;
    final openLabel = color != null
        ? 'Open the color image'
        : (open == null ? null : 'Open the ${open.filter ?? 'newest'} master');
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      container: true,
      label: target.key,
      child: Container(
        key: const ValueKey('darkroom_target_hero'),
        height: _heroHeight,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusLg,
          border: Border.all(color: colors.border),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Targets sit near the middle of their frames, so the image is
            // drawn wider than the card with its center to the right of the
            // text: the subject lands beside the name instead of under it.
            ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, box) {
                  final width = box.maxWidth * _heroImageScale;
                  return Stack(
                    children: [
                      Positioned(
                        left: box.maxWidth *
                                (tilesInHero
                                    ? _heroImageCenter
                                    : _heroImageCenterAlone) -
                            width / 2,
                        top: 0,
                        bottom: 0,
                        width: width,
                        child: DarkroomPreviewImage(
                          path: hero?.previewPngPath,
                          decodeWidth: (width * dpr).round(),
                          placeholderIcon: SkotiqIcons.star,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    colors.background.withValues(alpha: .94),
                    colors.background.withValues(alpha: .66),
                    colors.background.withValues(alpha: 0),
                  ],
                  stops: const [0, .32, .58],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.space2xl + 4,
                SkotiqTokens.space2xl,
                SkotiqTokens.space2xl + 4,
                SkotiqTokens.space2xl,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          darkroomHeroOverline(target),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.monoXs.copyWith(
                            color: colors.textSecondary,
                            letterSpacing: 1.3,
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              target.key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SkotiqTypography.heroTitle.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: SkotiqTokens.spaceMd),
                            Text(
                              darkroomHeroSentence(target, job),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: SkotiqTypography.bodyLg.copyWith(
                                color:
                                    colors.textPrimary.withValues(alpha: .85),
                              ),
                            ),
                            const SizedBox(height: SkotiqTokens.spaceXl),
                            Wrap(
                              spacing: SkotiqTokens.spaceSm,
                              runSpacing: SkotiqTokens.spaceSm,
                              children: [
                                Tooltip(
                                  message: buildReason ??
                                      'Check the framing of every sub, then '
                                          'build linear masters per filter.',
                                  child: SkotiqButton(
                                    key: const ValueKey(
                                      'darkroom_hero_build',
                                    ),
                                    label: 'Build masters',
                                    icon: SkotiqIcons.layers,
                                    size: ButtonSize.large,
                                    onPressed: buildReason != null
                                        ? null
                                        : () => context.go(
                                              darkroomFramingLocation(
                                                target.key,
                                              ),
                                            ),
                                  ),
                                ),
                                if (open != null && openLabel != null)
                                  SkotiqButton(
                                    key: const ValueKey('darkroom_hero_open'),
                                    label: openLabel,
                                    variant: ButtonVariant.secondary,
                                    size: ButtonSize.large,
                                    onPressed: () => context.push(
                                      darkroomEditLocation(masterId: open.id),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (tilesInHero) ...[
                    const SizedBox(width: SkotiqTokens.space2xl),
                    _ChannelTiles(target: target),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTiles extends ConsumerWidget {
  const _ChannelTiles({required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matches =
        ref.watch(darkroomTargetCalibrationProvider(target.key)).valueOrNull;
    final choices = ref.watch(darkroomFlatChoicesProvider(target.key));
    return Semantics(
      container: true,
      label: 'Channels',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, ch) in target.channels.indexed) ...[
            if (i > 0) const SizedBox(width: SkotiqTokens.spaceSm + 2),
            _ChannelTile(
              channel: ch,
              flat: matches == null
                  ? null
                  : darkroomFlatFor(ch.filter, matches, choices) != null,
            ),
          ],
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.flat});

  final DarkroomChannel channel;

  /// Whether a flat is ready; null while the library is read.
  final bool? flat;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final master = channel.master;
    final hours = master != null
        ? master.totalIntegrationSeconds / 3600
        : channel.keptSeconds / 3600;
    final flatText = switch (flat) {
      null => ' ',
      true => 'Flat ready',
      false => 'No flat',
    };
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tile = Container(
      width: _tileWidth,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: .72),
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.borderHighlight.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: SkotiqTokens.borderRadiusXs,
            child: SizedBox.square(
              dimension: _tileThumb,
              child: DarkroomPreviewImage(
                path: master?.previewPngPath,
                decodeWidth: (_tileThumb * 2 * dpr).round(),
                placeholderIcon: SkotiqIcons.layers,
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs + 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  channel.filter,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              Text(
                '${hours.toStringAsFixed(1)} h',
                style: SkotiqTypography.monoXs.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          Text(
            master == null ? 'Not built' : flatText,
            maxLines: 1,
            style: SkotiqTypography.captionSm.copyWith(
              color: master == null || flat == false
                  ? colors.brandWarm
                  : colors.textSecondary,
            ),
          ),
        ],
      ),
    );
    final label = '${channel.filter}: '
        '${master == null ? 'not built, ${hours.toStringAsFixed(1)} hours of kept subs' : '${hours.toStringAsFixed(1)} hour master'}'
        '${flat == null ? '' : (flat! ? ', flat ready' : ', no flat')}';
    if (master == null) {
      return Semantics(label: label, excludeSemantics: true, child: tile);
    }
    void open() => context.push(darkroomEditLocation(masterId: master.id));
    return Semantics(
      button: true,
      enabled: true,
      label: '$label. Open in Edit.',
      onTap: open,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('darkroom_channel_${channel.filter}'),
          onTap: open,
          child: tile,
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = SkotiqTypography.caption.copyWith(
      color: colors.textSecondary,
    );
    Widget swatch(Color c, {double opacity = .92}) => Container(
          width: 3,
          height: 12,
          color: c.withValues(alpha: opacity),
        );
    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: 5),
            Text(label, style: style),
          ],
        );
    final filters = {
      for (final n in target.nights)
        for (final f in n.filters) f,
    }.toList()
      ..sort(compareDarkroomFilters);
    final hasPause = target.nights.any((n) => n.pauses.isNotEmpty);
    final hasDim = target.nights.any((n) => n.rejected > 0 || n.offTarget > 0);
    return Wrap(
      spacing: SkotiqTokens.spaceMd + 2,
      runSpacing: SkotiqTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final f in filters)
          item(swatch(darkroomFilterColor(f, colors)), f),
        if (hasPause)
          item(
            SizedBox(
              width: 16,
              height: 9,
              child: CustomPaint(painter: _HatchSwatch(colors.borderHighlight)),
            ),
            'Paused',
          ),
        if (hasDim)
          item(
            swatch(colors.textPrimary, opacity: .25),
            'Rejected or off target',
          ),
      ],
    );
  }
}

class _HatchSwatch extends CustomPainter {
  _HatchSwatch(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    for (var x = -size.height; x < size.width; x += 5) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HatchSwatch old) => old.color != color;
}

class _LastMasters extends StatelessWidget {
  const _LastMasters({required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final latest = target.latestMasters;
    final nights =
        target.nights.where((n) => n.use != DarkroomNightUse.none).length;
    final newest = latest.isEmpty
        ? null
        : latest.map((m) => m.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
    return DarkroomTargetPanel(
      key: const ValueKey('darkroom_last_masters'),
      title: 'Last masters',
      trailing: newest == null
          ? null
          : Text(
              '${darkroomShortDate(newest)}'
              '${nights == 0 ? '' : ' · $nights night${nights == 1 ? '' : 's'}'}',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
      child: latest.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Text(
                'No masters yet. Build masters to make the first set.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final m in latest) _MasterRow(master: m)],
            ),
    );
  }
}

class _MasterRow extends StatelessWidget {
  const _MasterRow({required this.master});

  final IntegratedMaster master;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final name = master.channels >= 3
        ? 'Color image'
        : '${master.filter ?? 'Unfiltered'} master';
    final path = master.masterFitsPath;
    final kind = [
      if (path != null && path.isNotEmpty)
        p.extension(path).replaceFirst('.', '').toUpperCase(),
      if (master.channels >= 3) '${master.channels} channels',
      '${master.frameCount} subs',
      describeIntegration(master.totalIntegrationSeconds),
    ].join(' · ');
    final missing = path == null || path.isEmpty || !File(path).existsSync();
    void open() => context.push(darkroomEditLocation(masterId: master.id));
    return Semantics(
      button: true,
      enabled: true,
      label: '$name, $kind${missing ? ', file not on this computer' : ''}. '
          'Open in Edit.',
      onTap: open,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('darkroom_last_master_${master.id}'),
        onTap: open,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (missing)
                Padding(
                  padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
                  child: Tooltip(
                    message: 'The file is not on this computer: $path',
                    child: Icon(
                      SkotiqIcons.warning,
                      size: SkotiqTokens.iconXs,
                      color: colors.warning,
                    ),
                  ),
                ),
              Text(
                kind,
                style: SkotiqTypography.monoXs.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobBanner extends ConsumerWidget {
  const _JobBanner({required this.job});

  final DarkroomBuildJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.read(darkroomBuildJobsProvider.notifier);
    void activity() => context.go(darkroomTabLocation(DarkroomTab.activity));
    final (tone, title, message, action) = switch (job.stage) {
      DarkroomJobStage.framing => (
          BannerTone.info,
          'Checking framing.',
          '${job.framesDone} of ${job.framesTotal} subs registered. '
              '${describeEta(job.eta)}.',
          SkotiqButton(
            label: 'Open the framing check',
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: () => context.go(darkroomFramingLocation(job.target)),
          ),
        ),
      DarkroomJobStage.building || DarkroomJobStage.exporting => (
          BannerTone.info,
          'Building masters.',
          '${job.message}. ${job.overallDone} of ${job.overallTotal} subs. '
              '${describeEta(job.eta)}.',
          SkotiqButton(
            label: 'Follow in Activity',
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: activity,
          ),
        ),
      DarkroomJobStage.awaitingReview => (
          BannerTone.warning,
          'The framing check is waiting for you.',
          job.message,
          SkotiqButton(
            label: 'Open the framing check',
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: () => context.go(darkroomFramingLocation(job.target)),
          ),
        ),
      DarkroomJobStage.done => (
          BannerTone.success,
          'Masters ready.',
          [
            if (job.message != 'Masters ready') job.message,
            if (job.directory != null) 'Saved in ${job.directory}.',
          ].join(' '),
          null,
        ),
      DarkroomJobStage.failed || DarkroomJobStage.stopped => (
          job.stage == DarkroomJobStage.failed
              ? BannerTone.error
              : BannerTone.warning,
          job.stage == DarkroomJobStage.failed
              ? 'The last build failed.'
              : 'The last build stopped.',
          job.error ?? job.message,
          job.directory != null && job.plan != null
              ? SkotiqButton(
                  label: 'Resume it',
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: () {
                    final folder = Directory(job.directory!);
                    jobs.dismiss();
                    unawaited(
                      jobs.resume(folder).catchError((Object e) {
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      }),
                    );
                  },
                )
              : null,
        ),
    };
    return SkotiqBanner(
      tone: tone,
      title: title,
      message: message,
      action: action,
      onDismiss: job.active ? null : jobs.dismiss,
    );
  }
}
