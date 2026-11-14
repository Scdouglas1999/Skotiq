import '../../../models/science/science_models.dart';
import '../../roles/host_data/host_science.dart';
import '../../roles/host_data/photometric_transforms.dart';

/// Transform fits made and stored by a linked host.
final class RemotePhotometricTransforms implements PhotometricTransforms {
  RemotePhotometricTransforms(this._host);

  final HostScience _host;

  @override
  Future<PhotometricTransformFit> fit({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
  }) async => (
    coefficients: await _host.computePhotometricTransform(
      starMatches: starMatches,
      filterName: filterName,
      equipmentProfileId: equipmentProfileId,
    ),
    refusal: null,
  );

  @override
  Future<void> save(PhotometricTransformCoefficients coefficients) =>
      _host.savePhotometricTransform(coefficients);
}
