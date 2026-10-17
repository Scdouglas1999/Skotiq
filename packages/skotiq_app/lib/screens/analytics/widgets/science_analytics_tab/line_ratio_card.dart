// Moving-object card, line-ratio card and metric line widgets.
part of '../science_analytics_tab.dart';

class _MovingObjectCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<MovingObjectCandidateRow> moving;
  final Widget? hubExportButton;

  const _MovingObjectCard({
    required this.colors,
    required this.moving,
    this.hubExportButton,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Moving Object Candidates',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (hubExportButton != null) hubExportButton!,
              const _ScienceInfoButton(title: 'Moving Object Candidates'),
            ],
          ),
          const SizedBox(height: 8),
          if (moving.isEmpty)
            Text(
              'No candidates detected in current session window.',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            )
          else
            ...moving.take(6).map(
                  (candidate) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            candidate.objectName ?? candidate.candidateId,
                            style: SkotiqTypography.labelSm.copyWith(
                              color: colors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${(candidate.confidence * 100).toStringAsFixed(0)}%',
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textSecondary),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${candidate.motionArcsecPerMinute.toStringAsFixed(2)}"/min',
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _LineRatioCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final int? sessionId;
  final List<LineRatioProductRow> lineRatios;

  const _LineRatioCard({
    required this.colors,
    required this.sessionId,
    required this.lineRatios,
  });

  @override
  ConsumerState<_LineRatioCard> createState() => _LineRatioCardState();
}

class _LineRatioCardState extends ConsumerState<_LineRatioCard> {
  bool _isGenerating = false;
  String? _statusMessage;
  int _operationGeneration = 0;

  @override
  void didUpdateWidget(covariant _LineRatioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _operationGeneration++;
      _isGenerating = false;
      _statusMessage = null;
    }
  }

  bool _ownsOperation(
    int generation,
    int sessionId,
    SkotiqBackend backend,
  ) {
    return generation == _operationGeneration &&
        widget.sessionId == sessionId &&
        identical(ref.read(backendProvider), backend);
  }

  void _handleBackendChanged(
    SkotiqBackend? previous,
    SkotiqBackend next,
  ) {
    if (previous == null ||
        identical(previous, next) ||
        !_isGenerating ||
        !mounted) {
      return;
    }
    _operationGeneration++;
    setState(() {
      _isGenerating = false;
      _statusMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, _handleBackendChanged);
    final scienceSettingsAsync = ref.watch(scienceSettingsProvider);
    final narrowbandEnabled =
        scienceSettingsAsync.valueOrNull?.narrowbandRatiosEnabled;
    final latest = widget.lineRatios.isEmpty ? null : widget.lineRatios.first;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Narrowband Ratios',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: widget.colors.textPrimary),
                ),
              ),
              const _ScienceInfoButton(title: 'Narrowband ratios'),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SkotiqButton(
              isLoading: _isGenerating,
              onPressed: _isGenerating
                  ? null
                  : narrowbandEnabled == null
                      ? null
                      : !narrowbandEnabled
                          ? () => context.push('/settings?section=science')
                          : widget.sessionId == null
                              ? null
                              : _generateLineRatios,
              label: narrowbandEnabled == null
                  ? 'Science settings unavailable'
                  : !narrowbandEnabled
                      ? 'Enable Narrowband Ratios in Settings'
                      : _isGenerating
                          ? 'Generating...'
                          : 'Generate From Session Frames',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
            ),
          ),
          const SizedBox(height: 8),
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _statusMessage!,
                style: SkotiqTypography.caption
                    .copyWith(color: widget.colors.textMuted),
              ),
            ),
          if (scienceSettingsAsync.hasError)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Could not load science settings: '
                      '${scienceSettingsAsync.error}',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.error),
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref.invalidate(scienceSettingsProvider),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else if (narrowbandEnabled == false)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Feature disabled globally. Turn on Narrowband line ratios in Settings > Science.',
                style: SkotiqTypography.caption
                    .copyWith(color: widget.colors.textMuted),
              ),
            ),
          if (latest == null)
            Text(
              'No line-ratio products generated yet.',
              style: SkotiqTypography.caption
                  .copyWith(color: widget.colors.textMuted),
            )
          else ...[
            _MetricLine(
              colors: widget.colors,
              label: 'SII/Ha',
              value: latest.ratioSiiHa,
            ),
            _MetricLine(
              colors: widget.colors,
              label: 'OIII/Ha',
              value: latest.ratioOiiiHa,
            ),
            _MetricLine(
              colors: widget.colors,
              label: 'SII/OIII',
              value: latest.ratioSiiOiii,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _generateLineRatios() async {
    final sessionId = widget.sessionId;
    if (sessionId == null || _isGenerating) return;
    final backend = ref.read(backendProvider);
    final generation = ++_operationGeneration;

    setState(() {
      _isGenerating = true;
      _statusMessage = null;
    });

    final ScienceSettings scienceSettings;
    try {
      scienceSettings = await ref.read(scienceSettingsProvider.future);
    } catch (error) {
      if (mounted && _ownsOperation(generation, sessionId, backend)) {
        setState(() {
          _statusMessage = 'Could not load science settings: $error';
          _isGenerating = false;
        });
      }
      return;
    }
    if (!mounted || !_ownsOperation(generation, sessionId, backend)) return;
    if (!scienceSettings.narrowbandRatiosEnabled) {
      setState(() {
        _statusMessage =
            'Narrowband ratios are disabled. Enable them in Settings > Science.';
        _isGenerating = false;
      });
      return;
    }

    try {
      if (backend is NetworkBackend) {
        final result = await backend.generateSessionLineRatios(sessionId);
        if (!mounted || !_ownsOperation(generation, sessionId, backend)) return;
        ref.invalidate(sessionLineRatioProductsProvider(sessionId));
        setState(() {
          final files = (result['files'] as List?)?.join(', ') ?? 'host frames';
          _statusMessage = 'Generated using $files.';
        });
        return;
      }

      final images =
          await ref.read(imagesDaoProvider).getImagesForSession(sessionId);
      if (!mounted || !_ownsOperation(generation, sessionId, backend)) return;
      final ha =
          _findLatestByFilter(images, {'ha', 'halpha', 'h-alpha', 'h alpha'});
      final oiii = _findLatestByFilter(images, {'oiii', 'o3'});
      final sii = _findLatestByFilter(images, {'sii', 's2'});

      if (ha == null || oiii == null || sii == null) {
        setState(() {
          _statusMessage =
              'Need latest H-alpha, OIII, and SII frames in this session.';
        });
        return;
      }

      await ref.read(scienceProcessingServiceProvider).generateLineRatios(
            sessionId: sessionId,
            set: NarrowbandSet(
              hAlphaPath: ha.filePath,
              oiiiPath: oiii.filePath,
              siiPath: sii.filePath,
            ),
            hAlphaImageId: ha.id,
            oiiiImageId: oiii.id,
            siiImageId: sii.id,
          );

      if (!mounted || !_ownsOperation(generation, sessionId, backend)) return;
      setState(() {
        _statusMessage =
            'Generated using ${ha.fileName}, ${oiii.fileName}, ${sii.fileName}.';
      });
    } catch (error) {
      if (mounted && _ownsOperation(generation, sessionId, backend)) {
        setState(() {
          _statusMessage = 'Line-ratio generation failed: $error';
        });
      }
    } finally {
      if (mounted && _ownsOperation(generation, sessionId, backend)) {
        setState(() => _isGenerating = false);
      }
    }
  }

  DbCapturedImage? _findLatestByFilter(
      List<DbCapturedImage> images, Set<String> names) {
    final filtered = images.where((image) {
      final filter = (image.filter ?? '').toLowerCase().trim();
      for (final name in names) {
        // Match on exact filter name or as a whole-word within the filter
        // string.  Prevents false positives like "Shah" matching "ha".
        if (filter == name) return true;
        final pattern =
            RegExp('(?:^|[\\s_-])${RegExp.escape(name)}(?:[\\s_-]|\$)');
        if (pattern.hasMatch(filter)) return true;
      }
      return false;
    }).toList();

    if (filtered.isEmpty) {
      return null;
    }

    filtered.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return filtered.first;
  }
}

class _MetricLine extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final double value;

  const _MetricLine({
    required this.colors,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
          Text(
            value.toStringAsFixed(3),
            style: SkotiqTypography.bodyStrong.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
