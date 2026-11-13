import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/roles/host_data/photometric_transforms.dart';
import '../../services/science/photometric_transform_service.dart';
import '../host_role.dart';

final photometricTransformServiceProvider =
    Provider<PhotometricTransformService>((ref) {
      return PhotometricTransformService(ref);
    });

/// The photometric transform fits of whichever machine is the imaging host.
final photometricTransformsProvider = hostRoleProvider<PhotometricTransforms>(
  here: (ref) => ref.watch(photometricTransformServiceProvider),
  linked: (ref, host) => host.photometricTransforms,
);
