import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../provider_reader.dart';

/// Where a channel's value is being applied.
class RuntimeApplyContext {
  const RuntimeApplyContext(this.reader, {this.networkBackend});

  /// A `Ref`, `ProviderContainer` or `WidgetRef` (see [readProvider]).
  final Object reader;

  /// The connection to the host when applying on a linked client; null when
  /// the host applies a client's report to its own providers.
  final NetworkBackend? networkBackend;

  T read<T>(ProviderListenable<T> provider) => readProvider(reader, provider);
}

/// One piece of runtime state the imaging host shares with linked clients.
///
/// A channel names a provider the screens read, says how its value travels as
/// JSON, and how a received value is written back into that provider. The host
/// publishes every change of [source]; a client applies it so its screens show
/// what the host shows. When [clientReports] is set the reverse also holds: a
/// value the client computes itself (its own centering run, its own autofocus
/// result) is sent to the host, which applies it and shares it with every other
/// client.
///
/// Values carry state, never image data: a frame travels as metadata and the
/// client fetches pixels through the existing frame endpoint.
abstract class RuntimeMirrorChannel<T> {
  const RuntimeMirrorChannel();

  /// Wire name of the channel. Stable across releases.
  String get key;

  ProviderListenable<T> get source;

  /// The JSON form of [value]; null when there is nothing to show. Must be
  /// `jsonEncode`-safe (no NaN or infinity).
  Map<String, dynamic>? encode(T value);

  /// Write a received value into the providers the screens read.
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value);

  /// Shortest gap between two publishes of this channel; changes inside the
  /// gap are coalesced to the newest value.
  Duration get minInterval => Duration.zero;

  /// Whether a linked client sends the values it computes itself to the host.
  bool get clientReports => false;

  T readSource(Object reader) => readProvider(reader, source);

  Map<String, dynamic>? encodeCurrent(Object reader) =>
      encode(readSource(reader));

  ProviderSubscription<T> listen(Ref ref, void Function(T value) onChange) =>
      ref.listen<T>(source, (_, next) => onChange(next));
}
