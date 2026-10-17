import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Names a sequence target should be recognised by when matching it against a
/// catalog object.
///
/// A `TargetHeaderNode` carries only a free-text `targetName` (its
/// `catalogTargetId` is a DB row id, runtime-only and never serialised), and
/// generators qualify that name — "M31 (Panel 1/9)" for a mosaic, "NGC 7000 —
/// East" for a hand-split field. Matching on the raw string alone would fail to
/// recognise the very targets the user is imaging, so the base designation
/// before the first qualifier is contributed as well.
///
/// The separator set matches `targetQueueNamesMatch` in the sequencer's Target
/// Queue panel, so "in the plan" means the same thing on both surfaces.
Set<String> sequenceTargetMatchKeys(String targetName) {
  final trimmed = targetName.trim();
  if (trimmed.isEmpty) return const {};

  final keys = <String>{trimmed};
  final separator = RegExp(r'[\s\(\[\{\-–—/:]');
  final firstBreak = trimmed.indexOf(separator);
  if (firstBreak > 0) {
    final base = trimmed.substring(0, firstBreak).trim();
    if (base.isNotEmpty) keys.add(base);
  }
  return keys;
}

/// Catalog ids / object names of every target in the sequence currently loaded
/// in the sequencer.
///
/// Shaped to match [observedCatalogIdsProvider] and [listedCatalogIdsProvider]
/// (a `Set<String>` of ids-or-names, matched leniently against a DSO's id, name,
/// Messier number and NGC/IC designation) so the sky renderer can consume it
/// the same way it consumes those two — see the note in the planetarium shell
/// for the renderer-side work that would need.
///
/// Empty when no sequence is loaded.
final sequencedObjectIdsProvider = Provider<Set<String>>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return const <String>{};

  final ids = <String>{};
  for (final node in sequence.nodes.values.whereType<TargetHeaderNode>()) {
    ids.addAll(sequenceTargetMatchKeys(node.targetName));
  }
  return ids;
});
