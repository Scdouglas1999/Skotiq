import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'adaptive_chart_container.dart';

part 'photometric_calibration_wizard/header_and_steps.dart';
part 'photometric_calibration_wizard/frame_selection.dart';
part 'photometric_calibration_wizard/star_matching.dart';
part 'photometric_calibration_wizard/coefficients.dart';
part 'photometric_calibration_wizard/save_navigation.dart';

/// Last-resort pixel scale (arcsec/pixel) used only when the rig geometry
/// cannot supply one. 1.5"/px is a reasonable mid-range value for typical
/// amateur deep-sky rigs; it is applied solely when both the sensor pitch and
/// the focal length are unavailable.
@visibleForTesting
const double kDefaultFallbackPixelScale = 1.5;

/// Compute image scale in arcsec/pixel from sensor pitch and focal length.
///
/// Standard small-angle formula: `206.265 * pixelSizeUm / focalLengthMm`
/// (206.265 = arcsec per radian / 1000, folding the µm→mm unit conversion).
/// Returns [kDefaultFallbackPixelScale] when either input is missing or
/// non-positive — we never invent a scale from a single known dimension.
///
/// Pure + [visibleForTesting] so the "compute from geometry, fall back only
/// when both inputs are missing" rule is unit-tested directly. Example: a
/// 3.76 µm sensor at 530 mm yields ~1.464"/px.
@visibleForTesting
double fallbackPixelScaleArcsecPerPixel({
  double? pixelSizeUm,
  double? focalLengthMm,
}) {
  if (pixelSizeUm == null ||
      pixelSizeUm <= 0 ||
      focalLengthMm == null ||
      focalLengthMm <= 0) {
    return kDefaultFallbackPixelScale;
  }
  return 206.265 * pixelSizeUm / focalLengthMm;
}

/// Multi-step calibration wizard dialog for computing photometric
/// transformation coefficients from standard star fields.
class PhotometricCalibrationWizard extends ConsumerStatefulWidget {
  const PhotometricCalibrationWizard({super.key});

  @override
  ConsumerState<PhotometricCalibrationWizard> createState() =>
      _PhotometricCalibrationWizardState();
}

class _PhotometricCalibrationWizardState
    extends ConsumerState<PhotometricCalibrationWizard> {
  /// Matches [AdaptiveChartContainer] on the residual plot below.
  static const double _frameSelectorPreferredHeight = 180;

  int _step = 0;
  String _filterName = '';
  final TextEditingController _filterController = TextEditingController();
  int? _selectedSessionId;

  /// One or more plate-solved frames feeding the fit. A single frame
  /// constrains zero point + color term; frames of the same field at
  /// DIFFERENT altitudes add airmass spread, which is what lets the fit
  /// recover a real atmospheric extinction coefficient.
  final Set<int> _selectedImageIds = <int>{};
  List<CatalogStarMatch> _starMatches = const [];
  PhotometricTransformCoefficients? _computedCoefficients;
  String _statusMessage = '';
  bool _isComputing = false;
  bool _isSaving = false;
  bool _fitAttempted = false;
  int _operationGeneration = 0;

  void _update(VoidCallback fn) => setState(fn);

  bool _isCurrentOperation(
    int generation,
    SkotiqBackend authority,
  ) {
    return mounted &&
        generation == _operationGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  void _retireAsyncWork() {
    _operationGeneration++;
    _isComputing = false;
    _isSaving = false;
  }

  @override
  void dispose() {
    _operationGeneration++;
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      _operationGeneration++;
      setState(() {
        _step = 0;
        _filterName = '';
        _filterController.clear();
        _selectedSessionId = null;
        _selectedImageIds.clear();
        _starMatches = const [];
        _computedCoefficients = null;
        _statusMessage = '';
        _isComputing = false;
        _isSaving = false;
        _fitAttempted = false;
      });
    });
    final colors = SkotiqColors.of(context);

    return SkotiqDialog(
      title: 'Photometric Calibration Wizard',
      icon: LucideIcons.sparkles,
      width: 680,
      height: 600,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildStepIndicator(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          switch (_step) {
            0 => _buildStep1SelectFrame(colors),
            1 => _buildStep2MatchStars(colors),
            2 => _buildStep3ComputeCoefficients(colors),
            3 => _buildStep4Save(colors),
            _ => const SizedBox.shrink(),
          },
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildNavigationButtons(colors),
        ],
      ),
    );
  }
}

/// Provider for session images (used by the calibration wizard).
///
/// Renamed from `sessionImagesProvider` (which collided with the in-memory
/// `sessionImagesProvider` in skotiq_core and the analytics
/// `dbSessionImagesProvider`) so importers don't have to `hide` declarations.
final calibrationSessionImagesProvider =
    FutureProvider.family<List<DbCapturedImage>, int>((ref, sessionId) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return backend.getSessionImageRows(sessionId).then(
          (rows) => rows
              .map((row) => DbCapturedImage.fromJson(row))
              .toList(growable: false),
        );
  }
  return ref.read(imagesDaoProvider).getImagesForSession(sessionId);
});
