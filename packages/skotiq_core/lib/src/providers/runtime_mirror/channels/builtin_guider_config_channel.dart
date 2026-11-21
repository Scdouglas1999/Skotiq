import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/backend/builtin_guider_config.dart';
import '../../guiding_provider.dart';
import '../runtime_mirror_channel.dart';

/// The built-in guider's settings. A change on one window is written once;
/// this carries the saved config to the host's other windows. Applying it
/// replaces the provider value and does not write back.
class BuiltinGuiderConfigChannel
    extends RuntimeMirrorChannel<AsyncValue<BuiltinGuiderConfig>> {
  const BuiltinGuiderConfigChannel();

  @override
  String get key => 'builtinGuiderConfig';

  @override
  get source => builtinGuiderConfigProvider;

  @override
  Map<String, dynamic>? encode(AsyncValue<BuiltinGuiderConfig> value) =>
      value.valueOrNull?.toJson();

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null) return;
    context
        .read(builtinGuiderConfigProvider.notifier)
        .applyHostConfig(BuiltinGuiderConfig.fromJson(value));
  }
}
