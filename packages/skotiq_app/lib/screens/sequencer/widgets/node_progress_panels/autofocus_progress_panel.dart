part of '../node_progress_panels.dart';

class _AutofocusProgressPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final double progressPercent;

  /// The sweep point the step last reported; null between points.
  final AutofocusInstructionProgressDetail? sweepPoint;

  const _AutofocusProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.sweepPoint,
  });

  @override
  ConsumerState<_AutofocusProgressPanel> createState() =>
      _AutofocusProgressPanelState();
}

class _AutofocusProgressPanelState
    extends ConsumerState<_AutofocusProgressPanel> {
  int _currentStarIndex = 0;
  bool _isRefreshing = false;
  List<StarCrop>? _refreshedCrops;
  AutofocusInstructionProgressDetail? _lastPoint;

  @override
  Widget build(BuildContext context) {
    // The curve and the star crops come with the focuser's own sweep reports,
    // which the autofocus overlay keeps for the run in flight.
    final sweep = ref.watch(autofocusOverlayProvider);
    final focusRange = sweep.isRunning ? sweep.focusRange : null;
    // Between points the step reports where the focuser is going; the panel
    // keeps the last measured point until the next one.
    final point = _lastPoint = widget.sweepPoint ?? _lastPoint;
    final hfr = point?.currentHfr;
    final stars = point?.starCount;

    final crops = focusRange == null ? const <StarCrop>[] : sweep.starCrops;
    if (_refreshedCrops != null &&
        crops.isNotEmpty &&
        crops.first.pixelsBase64 != _refreshedCrops!.first.pixelsBase64) {
      _refreshedCrops = null;
    }
    final starCrops = _refreshedCrops ?? crops;
    if (_currentStarIndex >= starCrops.length) _currentStarIndex = 0;

    return _ProgressPanelContainer(
      colors: widget.colors,
      accentColor: widget.colors.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(point?.step, point?.totalSteps),
          const SizedBox(height: 12),
          if (focusRange == null)
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: widget.colors.surface,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
                border: Border.all(color: widget.colors.border),
              ),
              child: Center(
                child: Text('Waiting for data...',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize10,
                        color: widget.colors.textMuted)),
              ),
            )
          else
            SizedBox(
              height: 120,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: widget.colors.surface,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline4),
                        border: Border.all(color: widget.colors.border),
                      ),
                      child: CustomPaint(
                        painter: _VCurvePainter(
                          colors: widget.colors,
                          points: sweep.vcurvePoints,
                          focusRange: focusRange,
                        ),
                        size: const Size(double.infinity, 120),
                      ),
                    ),
                  ),
                  if (starCrops.isNotEmpty)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: _StarZoomPanel(
                        colors: widget.colors,
                        starCrops: starCrops,
                        currentIndex: _currentStarIndex,
                        isRefreshing: _isRefreshing,
                        onPrevious: () => setState(() {
                          _currentStarIndex =
                              (_currentStarIndex - 1 + starCrops.length) %
                                  starCrops.length;
                        }),
                        onNext: () => setState(() {
                          _currentStarIndex =
                              (_currentStarIndex + 1) % starCrops.length;
                        }),
                        onRefresh: _refreshStarCrops,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              _StatBox(
                  colors: widget.colors,
                  label: 'HFR',
                  value: hfr?.toStringAsFixed(2) ?? '--',
                  unit: 'px',
                  color: widget.colors.primary),
              const SizedBox(width: 16),
              _StatBox(
                  colors: widget.colors,
                  label: 'Stars',
                  value: stars?.toString() ?? '--',
                  unit: '',
                  color: widget.colors.success),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          _AnimatedProgressBar(
              colors: widget.colors,
              progress: widget.progressPercent / 100.0,
              color: widget.colors.primary),
        ],
      ),
    );
  }

  Future<void> _refreshStarCrops() async {
    if (_isRefreshing) return;

    setState(() {
      _isRefreshing = true;
    });

    try {
      final cameraState = ref.read(cameraStateProvider);
      final deviceId = cameraState.deviceId;

      if (deviceId == null) {
        if (mounted) {
          context.showWarningSnackBar('No camera connected');
        }
        return;
      }

      final backend = ref.read(imagingBackendProvider);
      final crops =
          await backend.getStarCropsFromLastImage(deviceId, maxCrops: 5);

      if (mounted) {
        setState(() {
          _refreshedCrops = crops;
          _currentStarIndex = 0;
        });

        if (crops.isEmpty) {
          context.showWarningSnackBar('No stars detected in image');
        }
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to refresh star crops: ${userFacingError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Widget _buildHeader(int? currentPoint, int? totalPoints) {
    return Row(
      children: [
        Icon(SkotiqIcons.crosshair, size: 16, color: widget.colors.primary),
        const SizedBox(width: 8),
        Text(
          'Autofocus',
          style: SkotiqTypography.labelStrongSm
              .copyWith(color: widget.colors.textPrimary),
        ),
        const Spacer(),
        if (currentPoint != null && totalPoints != null)
          Text(
            'Point $currentPoint of $totalPoints',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: widget.colors.textMuted),
          ),
      ],
    );
  }
}
