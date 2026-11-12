import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _LinkedHost extends Mock implements NetworkBackend {}

/// What a linked client does with the host's open plan as the `openPlan`
/// channel delivers it. A null [document] is a host with no plan open.
void showHostOpenPlan(
  ProviderContainer client,
  Map<String, dynamic>? document,
) => const OpenPlanChannel().apply(
  RuntimeApplyContext(client, networkBackend: _LinkedHost()),
  document,
);
