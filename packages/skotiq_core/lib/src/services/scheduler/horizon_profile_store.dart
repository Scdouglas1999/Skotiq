import '../../database/database.dart';
import '../../models/site/horizon_profile.dart';

/// The custom horizons stored in [db], in the order they were added.
Future<List<HorizonProfile>> loadHorizonProfiles(SkotiqDatabase db) async => [
  for (final row in await db.planningDao.allHorizonProfiles())
    HorizonProfile.fromRow(
      id: row.id,
      name: row.name,
      samplesJson: row.samplesJson,
    ),
];
