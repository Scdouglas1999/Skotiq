import 'dart:typed_data';

import '../../../database/database.dart';
import '../../../models/science/science_models.dart';
import '../../../models/backend/remote_science_bundle.dart';

/// Science products a linked imaging host derives from its frames:
/// photometry, transforms, reports and their settings.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostScience {
  Future<PhotometricTransformCoefficients?> computePhotometricTransform({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
  });

  Future<Uint8List> exportSessionAavso(
    int sessionId, {
    required String targetStarName,
    String? filterBand,
    String? chartId,
  });

  Future<Uint8List> generateObservationReport(int sessionId);

  Future<Map<String, dynamic>> generateSessionLineRatios(int sessionId);

  Future<({int width, int height})?> getFitsDimensions(String hostPath);

  Future<List<PsfFieldTileRow>> getSessionPsfTiles(int sessionId);

  Future<RemoteScienceBundle> getSessionlessScienceBundle();

  Future<int> savePhotometricTransform(
    PhotometricTransformCoefficients coefficients,
  );
}
