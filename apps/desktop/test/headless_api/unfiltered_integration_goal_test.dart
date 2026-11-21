import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/handlers/planning_data_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  test('an empty filter is an unfiltered integration goal', () async {
    final container = createHeadlessTestContainer();
    addTearDown(container.dispose);
    final targetId = await container.read(databaseProvider).targetsDao.createTarget(
      TargetsCompanion.insert(name: 'M31', ra: 0.7123, dec: 41.269),
    );
    final handlers = PlanningDataHandlers(container);

    final missing = await translateHandlerErrors(
      handlers.handleGetCapturedFrameCount(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/integration-goals/captured-count?targetId=$targetId',
          ),
        ),
      ),
    );
    expect(missing.statusCode, HttpStatus.badRequest);

    final counted = await handlers.handleGetCapturedFrameCount(
      Request(
        'GET',
        Uri.parse(
          'http://localhost/api/integration-goals/captured-count'
          '?targetId=$targetId&filter=',
        ),
      ),
    );
    expect(counted.statusCode, HttpStatus.ok);
    final countedBody = jsonDecode(await counted.readAsString()) as Map;
    expect(countedBody['count'], 0);

    final saved = await translateHandlerErrors(
      handlers.handleUpsertIntegrationGoal(
        Request(
          'POST',
          Uri.parse('http://localhost/api/integration-goals'),
          body: jsonEncode({
            'targetId': targetId,
            'filter': '',
            'exposureSeconds': 180,
            'frameCount': 20,
            'priority': 5,
          }),
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    expect(saved.statusCode, HttpStatus.ok);

    final listed = await handlers.handleGetIntegrationGoals(
      Request(
        'GET',
        Uri.parse(
          'http://localhost/api/integration-goals?targetId=$targetId',
        ),
      ),
    );
    expect(listed.statusCode, HttpStatus.ok);
    final goals = (jsonDecode(await listed.readAsString()) as Map)['goals'] as List;
    expect(goals, hasLength(1));
    expect(goals.single['filter'], '');
    expect(goals.single['exposureSeconds'], 180);
    expect(goals.single['frameCount'], 20);
  });
}
