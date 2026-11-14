import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/science/aavso_export_service.dart';
import '../app_version_provider.dart';
import '../database_provider.dart';

/// The one [AavsoExportService], naming this build in `#SOFTWARE`: the
/// Analytics AAVSO export on this machine and the host's export endpoint
/// both use it.
final aavsoExportServiceProvider = Provider<AavsoExportService>(
  (ref) => AavsoExportService(
    scienceDao: ref.watch(scienceDaoProvider),
    settingsDao: ref.watch(settingsDaoProvider),
    imagesDao: ref.watch(imagesDaoProvider),
    softwareLabel: ref.watch(appVersionLabelProvider),
  ),
);
