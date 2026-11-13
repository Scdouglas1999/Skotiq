import '../../../models/science/science_models.dart';

/// Photometric transform fits of the imaging host: worked out from matched
/// catalog stars and stored with the host's equipment profile.
abstract interface class PhotometricTransforms {
  /// The fit for [starMatches], or no coefficients and, when the host said
  /// why, the reason no fit could be made.
  Future<PhotometricTransformFit> fit({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
  });

  Future<void> save(PhotometricTransformCoefficients coefficients);
}

typedef PhotometricTransformFit = ({
  PhotometricTransformCoefficients? coefficients,
  String? refusal,
});
