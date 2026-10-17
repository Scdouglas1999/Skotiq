import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/planning_data_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('PlanningDataHandlers query validation', () {
    late ProviderContainer container;
    late PlanningDataHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = PlanningDataHandlers(container);
    });

    tearDown(() => container.dispose());

    test(
      'optional target filter cannot silently become an all-record query',
      () async {
        for (final targetId in const ['abc', '0', '-1']) {
          final response = await translateHandlerErrors(
            handlers.handleGetIntegrationGoals(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/integration-goals?targetId=$targetId',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: targetId);
        }
      },
    );

    test('delete requires exactly one valid selector', () async {
      final methods = <Future<Response> Function(Request)>[
        handlers.handleDeleteIntegrationGoal,
        handlers.handleDeleteTargetConstraint,
      ];
      for (final method in methods) {
        for (final query in const [
          '',
          'id=abc',
          'id=0',
          'all=maybe',
          'all=true&id=1',
          'targetId=1&id=2',
        ]) {
          final suffix = query.isEmpty ? '' : '?$query';
          final response = await translateHandlerErrors(
            method(
              Request(
                'DELETE',
                Uri.parse('http://localhost/api/planning/delete$suffix'),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: query);
        }
      }
    });

    test('project endpoints require positive project IDs', () async {
      final methods = <Future<Response> Function(Request)>[
        handlers.handleGetProjectTargets,
        handlers.handleGetProjectProgress,
      ];
      for (final method in methods) {
        for (final projectId in const ['', 'abc', '0', '-1']) {
          final suffix = projectId.isEmpty ? '' : '?projectId=$projectId';
          final response = await translateHandlerErrors(
            method(
              Request(
                'GET',
                Uri.parse('http://localhost/api/projects/test$suffix'),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: projectId);
        }
      }
    });
  });
}
