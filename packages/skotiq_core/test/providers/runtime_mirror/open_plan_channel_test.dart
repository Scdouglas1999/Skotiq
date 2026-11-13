// The plan open in the host's editor is one value the host and its linked
// clients show, including on a client that links after it was opened.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import 'mirror_link.dart';

Sequence _plan(String name, {int? databaseId}) => Sequence.create(
  id: 'seq',
  name: name,
  rootNodeId: 'target',
  nodes: {
    'target': TargetHeaderNode(
      id: 'target',
      targetName: 'M31',
      raHours: 0.712,
      decDegrees: 41.269,
      childIds: const ['frames'],
    ),
    'frames': ExposureNode(
      id: 'frames',
      parentId: 'target',
      durationSecs: 60,
      count: 5,
      frameType: FrameType.light,
    ),
  },
).copyWith(databaseId: databaseId);

const _planInterval = Duration(milliseconds: 500);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a client that links after the host opened a plan shows it, and '
      'follows the host closing it', () async {
    final host = mirrorHost();
    final editor = host.container.read(currentSequenceProvider.notifier);
    editor.loadSequence(_plan('Tonight M31', databaseId: 7));
    await settle(_planInterval);

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    final shown = client.container.read(currentSequenceProvider);
    expect(shown?.name, 'Tonight M31');
    expect(shown?.databaseId, 7);
    expect(
      client.container.read(currentSequenceProvider.notifier).isDirty,
      isFalse,
    );

    editor.applyPeerEdit(null, dirty: false);
    await settle(_planInterval);
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(client.container.read(currentSequenceProvider), isNull);
  });

  test('the plan a planner put in the host\'s editor arrives with its '
      'owner', () async {
    final host = mirrorHost();
    host.container.read(currentSequenceProvider.notifier)
      ..loadSequence(_plan('Autopilot pick'))
      ..adoptOwner(ActivePlanOwner.autopilot);
    await settle(_planInterval);

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(client.container.read(currentSequenceProvider)?.name, 'Autopilot pick');
    expect(
      client.container.read(activePlanOwnerProvider),
      ActivePlanOwner.autopilot,
    );
  });

  test('the channel carries the document the editor-sequence endpoint '
      'serves, so an older client reads the same plan there', () async {
    final host = mirrorHost();
    final plan = _plan('Tonight M31', databaseId: 7);
    host.container.read(currentSequenceProvider.notifier).loadSequence(plan);
    await settle(_planInterval);

    final sent = host.container
        .read(hostRuntimeStateStoreProvider)
        .snapshot()
        .singleWhere((update) => update.channel == 'openPlan')
        .value;
    expect(
      sent,
      openPlanDocument(
        host.container.read(sequenceFileServiceProvider),
        plan,
        unsaved: false,
        owner: ActivePlanOwner.manual,
      ),
    );
    expect(sent?.keys, containsAll(['sequence', 'databaseId', 'isDirty']));
  });

  test('a plan the client still holds unsent edits to is not replaced by a '
      're-read of the host\'s', () async {
    final host = mirrorHost();
    host.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(_plan('Host plan'));
    await settle(_planInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    client.container.read(currentSequenceProvider.notifier).setName('Mine');
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(client.container.read(currentSequenceProvider)?.name, 'Mine');
  });
}
