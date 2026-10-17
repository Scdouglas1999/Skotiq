part of '../node_progress_panels.dart';

class _AutofocusProgressPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final double progressPercent;
  final String detail;

  const _AutofocusProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.detail,
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

  @override
  Widget build(BuildContext context) {
    // Try to parse structured JSON progress data
    final afData = AutofocusProgressData.tryParse(widget.detail);

    // Compatibility fallback: older / remote backends that have not been
    // upgraded to the structured autofocus payload still emit a plain
    // "Point 5/9: HFR=..., Stars=..." string. The structured path is
    // preferred; the legacy regex panel only runs when parsing fails. Kept
    // until every shipped backend is confirmed to emit the structured data.
    if (afData == null) {
      return _buildLegacyPanel();
    }

    return _buildEnhancedPanel(afData);
  }

  Widget _buildLegacyPanel() {
    // Parse detail: "Point 5/9: HFR=2.45, Stars=127"
    final pointMatch = RegExp(r'Point (\d+)/(\d+)').firstMatch(widget.detail);
    final hfrMatch =
        RegExp(r'HFR[=:]?\s*(\d+\.?\d*)').firstMatch(widget.detail);
    final starsMatch = RegExp(r'Stars[=:]?\s*(\d+)').firstMatch(widget.detail);

    final currentPoint = int.tryParse(pointMatch?.group(1) ?? '');
    final totalPoints = int.tryParse(pointMatch?.group(2) ?? '');
    final hfr = double.tryParse(hfrMatch?.group(1) ?? '');
    final stars = int.tryParse(starsMatch?.group(1) ?? '');

    return _ProgressPanelContainer(
      colors: widget.colors,
      accentColor: widget.colors.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(currentPoint, totalPoints),
          const SizedBox(height: 12),
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
          const SizedBox(height: 12),
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
      // Get the camera device ID from the camera state
      final cameraState = ref.read(cameraStateProvider);
      final deviceId = cameraState.deviceId;

      if (deviceId == null) {
        if (mounted) {
          context.showWarningSnackBar('No camera connected');
        }
        return;
      }

      // Request fresh star crops from the backend
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
        context.showErrorSnackBar('Failed to refresh star crops: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Widget _buildEnhancedPanel(AutofocusProgressData data) {
    // Use refreshed crops if available, otherwise use data from progress events
    final starCrops = _refreshedCrops ?? data.starCrops;

    // Ensure star index is valid
    if (_currentStarIndex >= starCrops.length) {
      _currentStarIndex = 0;
    }

    // Clear refreshed crops when new progress data arrives with different crops
    if (_refreshedCrops != null &&
        data.starCrops.isNotEmpty &&
        data.starCrops.first.pixelsBase64 !=
            _refreshedCrops!.first.pixelsBase64) {
      _refreshedCrops = null;
    }

    return _ProgressPanelContainer(
      colors: widget.colors,
      accentColor: widget.colors.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(data.point, data.totalPoints),
          const SizedBox(height: 12),

          // V-curve with star zoom overlay
          SizedBox(
            height: 120,
            child: Stack(
              children: [
                // V-curve chart (fills the whole area)
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
                        points: data.vcurvePoints,
                        focusRange: data.focusRange,
                      ),
                      size: const Size(double.infinity, 120),
                    ),
                  ),
                ),

                // Star zoom panel (top-left corner overlay)
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

          // Stats row
          Row(
            children: [
              _StatBox(
                  colors: widget.colors,
                  label: 'HFR',
                  value: data.hfr.toStringAsFixed(2),
                  unit: 'px',
                  color: widget.colors.primary),
              const SizedBox(width: 16),
              _StatBox(
                  colors: widget.colors,
                  label: 'Stars',
                  value: data.starCount.toString(),
                  unit: '',
                  color: widget.colors.success),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),

          // Progress bar
          _AnimatedProgressBar(
              colors: widget.colors,
              progress: widget.progressPercent / 100.0,
              color: widget.colors.primary),
        ],
      ),
    );
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

/// Star zoom panel with navigation arrows
