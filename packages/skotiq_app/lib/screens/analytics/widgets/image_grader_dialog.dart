// Image Grader: bulk frame rejection by per-frame quality thresholds.
//
// This is the "drag-the-bar to reject everything above HFR 2.8 / star count
// below 60" feature that SGP users love and that NINA's Auto-Focus After
// only approximates. We compute a live preview as the user moves sliders,
// then commit with one Apply press.
//
// Important: this never *deletes* image files — it only flips the database
// `isAccepted` flag (with a rejection reason). Acceptance restoration is
// a single tap on the rejected card.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/authority_bound_dialog.dart';
import '../analytics_screen.dart' show dbSessionImagesProvider;

part 'image_grader_dialog_parts/_threshold_controls.dart';

typedef ImageGraderPsfMetric = ({double? fwhm, double? eccentricity});

/// Load the PSF metrics used by the grader from the authoritative host.
///
/// A mobile companion has its own (normally empty) local database, so reading
/// [ScienceDao] there silently disables the FWHM and eccentricity rules. The
/// network backend already exposes the host's session science products; local
/// mode continues to read Drift directly.
Future<Map<int, ImageGraderPsfMetric>> loadImageGraderPsfMetrics({
  required SkotiqBackend backend,
  required ScienceDao? localScienceDao,
  required List<DbCapturedImage> frames,
  int? sessionId,
}) async {
  final frameIds = frames.map((frame) => frame.id).toSet();
  final tiles = <PsfFieldTileRow>[];

  if (backend is NetworkBackend) {
    if (sessionId != null) {
      tiles.addAll(await backend.getSessionPsfTiles(sessionId));
    } else {
      tiles.addAll((await backend.getSessionlessScienceBundle()).psfTiles);
    }
  } else {
    final dao = localScienceDao;
    if (dao == null) {
      throw StateError('A local science database is required in local mode');
    }
    if (sessionId != null) {
      tiles.addAll(await dao.getPsfTilesForSession(sessionId));
    } else {
      for (final frame in frames) {
        tiles.addAll(await dao.getPsfTilesForImage(frame.id));
      }
    }
  }

  final grouped = <int, List<PsfFieldTileRow>>{};
  for (final tile in tiles) {
    final imageId = tile.capturedImageId;
    if (imageId == null || !frameIds.contains(imageId)) continue;
    grouped.putIfAbsent(imageId, () => []).add(tile);
  }

  final result = <int, ImageGraderPsfMetric>{};
  for (final entry in grouped.entries) {
    final fwhms = <double>[];
    final eccentricities = <double>[];
    for (final tile in entry.value) {
      if (tile.starCount <= 0) continue;
      if (tile.medianFwhm.isFinite && tile.medianFwhm > 0) {
        fwhms.add(tile.medianFwhm);
      }
      if (tile.medianEccentricity.isFinite && tile.medianEccentricity > 0) {
        eccentricities.add(tile.medianEccentricity);
      }
    }
    final fwhm = _imageGraderMedian(fwhms);
    final eccentricity = _imageGraderMedian(eccentricities);
    if (fwhm != null || eccentricity != null) {
      result[entry.key] = (fwhm: fwhm, eccentricity: eccentricity);
    }
  }
  return result;
}

double? _imageGraderMedian(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = values.toList(growable: false)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2.0;
}

FrameGradeRules resolveImageGraderRules(
  ScienceSettings settings,
  List<DbCapturedImage> frames,
) {
  final persisted = settings.resolvedFrameGradeRules();
  return persisted.isEmpty ? FrameGradeRules.suggestFrom(frames) : persisted;
}

class ImageGraderDialog extends ConsumerStatefulWidget {
  final List<DbCapturedImage> frames;
  final int? sessionId;

  const ImageGraderDialog({
    super.key,
    required this.frames,
    this.sessionId,
  });

  static Future<int?> show(
    BuildContext context, {
    required List<DbCapturedImage> frames,
    int? sessionId,
  }) {
    return showDialog<int>(
      context: context,
      builder: (_) => ImageGraderDialog(frames: frames, sessionId: sessionId),
    );
  }

  @override
  ConsumerState<ImageGraderDialog> createState() => _ImageGraderDialogState();
}

class _ImageGraderDialogState extends ConsumerState<ImageGraderDialog> {
  FrameGradeRules _rules = const FrameGradeRules();
  bool _rulesLoading = true;
  String? _rulesError;
  bool _applying = false;
  String? _applyError;

  /// Per-frame field medians from the science PSF tiles. FWHM and
  /// eccentricity are not persisted on captured_images, so the grader
  /// sources them here — same data the capture-time auto-grader uses, so
  /// the preview and the automatic path can never disagree. Frames without
  /// PSF products simply have no entry and skip those rules.
  Map<int, ImageGraderPsfMetric> _psfMetricsByImage = const {};
  bool _psfMetricsLoading = true;
  String? _psfMetricsError;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _authorityGeneration = 0;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _authorityGeneration++;
        setState(() {
          _applying = false;
          _applyError = 'Connected rig changed; reopen the grader to continue.';
        });
        closeAuthorityBoundDialog(context);
      },
    );
    unawaited(_loadRules());
    unawaited(_loadPsfMetrics());
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _loadRules() async {
    if (_rulesError != null) {
      ref.invalidate(scienceSettingsProvider);
    }
    if (!_rulesLoading) {
      setState(() {
        _rulesLoading = true;
        _rulesError = null;
      });
    }
    try {
      final settings = await ref.read(scienceSettingsProvider.future);
      if (mounted) {
        setState(() {
          _rules = resolveImageGraderRules(settings, widget.frames);
          _rulesLoading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _rulesLoading = false;
          _rulesError = error.toString();
        });
      }
    }
  }

  Future<void> _loadPsfMetrics() async {
    if (!_psfMetricsLoading) {
      setState(() {
        _psfMetricsLoading = true;
        _psfMetricsError = null;
      });
    }
    final backend = ref.read(backendProvider);
    final generation = _authorityGeneration;
    try {
      final result = await loadImageGraderPsfMetrics(
        backend: backend,
        localScienceDao:
            backend is NetworkBackend ? null : ref.read(scienceDaoProvider),
        frames: widget.frames,
        sessionId: widget.sessionId,
      );
      if (_isCurrentAuthority(backend, generation)) {
        setState(() {
          _psfMetricsByImage = result;
          _psfMetricsLoading = false;
        });
      }
    } catch (error) {
      if (_isCurrentAuthority(backend, generation)) {
        setState(() {
          _psfMetricsLoading = false;
          _psfMetricsError = error.toString();
        });
      }
    }
  }

  bool _isCurrentAuthority(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _authorityGeneration &&
      identical(ref.read(backendProvider), backend);

  ({
    int rejected,
    int accepted,
    List<({DbCapturedImage frame, String reason})> rejections
  }) _preview() {
    final rejections = <({DbCapturedImage frame, String reason})>[];
    var rejected = 0;
    for (final f in widget.frames) {
      final metrics = _psfMetricsByImage[f.id];
      final reason = _rules.gradeFrame(
        f,
        fwhm: metrics?.fwhm,
        eccentricity: metrics?.eccentricity,
      );
      if (reason != null) {
        rejected++;
        rejections.add((frame: f, reason: reason));
      }
    }
    return (
      rejected: rejected,
      accepted: widget.frames.length - rejected,
      rejections: rejections,
    );
  }

  Future<void> _apply() async {
    if (_applying) return;
    final backend = ref.read(backendProvider);
    final generation = _authorityGeneration;
    final preview = _preview();
    if (preview.rejections.isEmpty) {
      Navigator.of(context).pop(0);
      return;
    }
    setState(() {
      _applying = true;
      _applyError = null;
    });
    try {
      await ref
          .read(scienceSettingsProvider.notifier)
          .setFrameGradeRules(_rules);
      if (!_isCurrentAuthority(backend, generation)) return;
      final repo = ref.read(imagingRecordsRepositoryProvider);
      for (final r in preview.rejections) {
        if (!_isCurrentAuthority(backend, generation)) return;
        await repo.rejectImage(r.frame.id, r.reason);
        if (!_isCurrentAuthority(backend, generation)) return;
      }
      if (!mounted) return;
      ref.invalidate(dbSessionImagesProvider);
      Navigator.of(context).pop(preview.rejected);
    } catch (e) {
      if (!_isCurrentAuthority(backend, generation)) return;
      setState(() {
        _applying = false;
        _applyError = e.toString();
      });
    }
  }

  String _activeRuleSummary() {
    final parts = <String>[
      if (_rules.maxHfr != null) 'HFR ≤ ${_rules.maxHfr!.toStringAsFixed(2)}',
      if (_rules.maxFwhm != null)
        'FWHM ≤ ${_rules.maxFwhm!.toStringAsFixed(2)}',
      if (_rules.maxEccentricity != null)
        'ecc ≤ ${_rules.maxEccentricity!.toStringAsFixed(2)}',
      if (_rules.minStars != null) 'stars ≥ ${_rules.minStars}',
      if (_rules.maxGuidingRmsTotalArcsec != null)
        'RMS ≤ ${_rules.maxGuidingRmsTotalArcsec!.toStringAsFixed(2)}"',
    ];
    return parts.isEmpty ? 'No active rules' : parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final preview = _preview();
    final frameCount = widget.frames.length;
    return SkotiqDialog(
      title: 'Image grader',
      icon: LucideIcons.sliders,
      width: 720,
      height: 640,
      closeEnabled: !_applying,
      actions: [
        SkotiqButton(
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          onPressed:
              _rulesLoading || _rulesError != null || preview.rejected == 0
                  ? null
                  : _apply,
          isLoading: _applying,
          label: preview.rejected == 0
              ? 'Nothing to reject'
              : 'Reject ${preview.rejected} frame'
                  '${preview.rejected == 1 ? "" : "s"}',
        ),
      ],
      // The dialog owns its scrolling: the list of frames about to be rejected
      // is pinned above the footer and scrolls inside its own box. Left in the
      // dialog's single scroll view it opened below the fold, half-hidden
      // behind the "Reject N frames" bar, so the confirmation list for a
      // destructive action was something the user had to go looking for.
      scrollableBody: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Mark frames as rejected when they exceed any threshold below. '
                    'Nothing is deleted — rejection can be undone per frame.',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    '$frameCount frame${frameCount == 1 ? "" : "s"} loaded',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
                  if (_rulesLoading) ...[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Text(
                      'Loading saved grading rules…',
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ] else if (_rulesError != null) ...[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Saved grading rules could not be loaded. Applying is '
                            'disabled to protect the existing settings.',
                            style: SkotiqTypography.captionSm.copyWith(
                              color: colors.error,
                            ),
                          ),
                        ),
                        TextButton(
                            onPressed: _loadRules, child: const Text('Retry')),
                      ],
                    ),
                  ],
                  const SizedBox(height: SkotiqTokens.spaceMd + 2),
                  _ThresholdSliders(
                    colors: colors,
                    rules: _rules,
                    frames: widget.frames,
                    psfMetricsByImage: _psfMetricsByImage,
                    onChanged: (next) => setState(() => _rules = next),
                  ),
                  if (_psfMetricsLoading) ...[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Text(
                      'Loading FWHM and eccentricity measurements…',
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ] else if (_psfMetricsError != null) ...[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'FWHM and eccentricity are unavailable. Those rules will '
                            'not be applied until the measurements load.',
                            style: SkotiqTypography.captionSm.copyWith(
                              color: colors.warning,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _loadPsfMetrics,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  _PreviewSummary(
                    colors: colors,
                    rejected: preview.rejected,
                    accepted: preview.accepted,
                    activeRules: _activeRuleSummary(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _RejectionList(
            colors: colors,
            rejections: preview.rejections,
          ),
          if (_applyError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              _applyError!,
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}
