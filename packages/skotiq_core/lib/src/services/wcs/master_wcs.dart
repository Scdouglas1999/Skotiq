import '../../models/imaging/integrated_master.dart';
import 'gnomonic_projection.dart';

extension IntegratedMasterWcs on IntegratedMaster {
  /// The master's plate-solved WCS, or null when it was never solved. A row
  /// without a stored reference pixel is referenced at the image centre.
  SolvedWcs? get solvedWcs => SolvedWcs.tryFromFits(
    crval1: wcsCrval1,
    crval2: wcsCrval2,
    crpix1: wcsCrpix1 ?? (width + 1) / 2,
    crpix2: wcsCrpix2 ?? (height + 1) / 2,
    cd1_1: wcsCd1_1,
    cd1_2: wcsCd1_2,
    cd2_1: wcsCd2_1,
    cd2_2: wcsCd2_2,
    imageWidth: width,
    imageHeight: height,
  );
}
