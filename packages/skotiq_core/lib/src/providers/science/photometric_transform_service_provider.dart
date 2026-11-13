import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/photometric_transform_service.dart';

final photometricTransformServiceProvider =
    Provider<PhotometricTransformService>((ref) {
      return PhotometricTransformService(ref);
    });
