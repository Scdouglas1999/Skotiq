import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The forecast cloud cover a linked client was given by its host.
///
/// Separate from the weather device's own cloud-cover reading. The host
/// does not read this; it keeps fetching. A client reads it instead of
/// calling the sky service.
final hostForecastCloudCoverProvider = StateProvider<double?>((ref) => null);
