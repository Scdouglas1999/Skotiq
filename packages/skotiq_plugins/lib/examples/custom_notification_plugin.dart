import 'dart:async';

import '../src/plugin_api.dart';

/// Condition evaluator that checks event data against a threshold.
///
/// Used by [CustomNotificationPlugin] to define notification rules.
class NotificationRule {
  /// Human-readable name for this rule
  final String name;

  /// Event name to monitor
  final String eventName;

  /// Field in the event data to evaluate
  final String dataField;

  /// Comparison operator: 'gt', 'lt', 'gte', 'lte', 'eq', 'neq'
  final String operator;

  /// Threshold value to compare against
  final double threshold;

  /// Notification message template. Use {value} for the actual value
  /// and {field} for the field name.
  final String messageTemplate;

  /// Minimum seconds between notifications for this rule to avoid spam
  final int cooldownSeconds;

  /// Last time this rule triggered a notification
  DateTime? _lastTriggered;

  NotificationRule({
    required this.name,
    required this.eventName,
    required this.dataField,
    required this.operator,
    required this.threshold,
    required this.messageTemplate,
    this.cooldownSeconds = 300,
  });

  /// Evaluate whether the condition is met for the given event data.
  ///
  /// Returns the notification message if the condition is met and the
  /// cooldown has elapsed, or null otherwise.
  String? evaluate(Map<String, dynamic> data) {
    final rawValue = data[dataField];
    if (rawValue == null) return null;

    final double value;
    if (rawValue is num) {
      value = rawValue.toDouble();
    } else if (rawValue is String) {
      final parsed = double.tryParse(rawValue);
      if (parsed == null) return null;
      value = parsed;
    } else {
      return null;
    }

    final conditionMet = switch (operator) {
      'gt' => value > threshold,
      'lt' => value < threshold,
      'gte' => value >= threshold,
      'lte' => value <= threshold,
      'eq' => value == threshold,
      'neq' => value != threshold,
      _ => false,
    };

    if (!conditionMet) return null;

    // Check cooldown
    final now = DateTime.now();
    if (_lastTriggered != null) {
      final elapsed = now.difference(_lastTriggered!).inSeconds;
      if (elapsed < cooldownSeconds) return null;
    }

    _lastTriggered = now;

    return messageTemplate
        .replaceAll('{value}', value.toStringAsFixed(2))
        .replaceAll('{field}', dataField)
        .replaceAll('{threshold}', threshold.toStringAsFixed(2));
  }

  /// Reset the cooldown timer for this rule
  void resetCooldown() {
    _lastTriggered = null;
  }
}

/// Plugin that monitors events and sends notifications when configurable
/// conditions are met.
///
/// Demonstrates:
/// - Subscribing to multiple event streams
/// - Configurable condition evaluation
/// - Emitting derived events (notifications)
/// - Cooldown logic to prevent notification spam
/// - Dynamic rule management
///
/// Usage:
/// ```dart
/// final plugin = CustomNotificationPlugin();
///
/// // Add rules before or after registration
/// plugin.addRule(NotificationRule(
///   name: 'High Wind Alert',
///   eventName: 'weather.updated',
///   dataField: 'windSpeed',
///   operator: 'gt',
///   threshold: 30.0,
///   messageTemplate: 'Wind speed {value} km/h exceeds {threshold} km/h',
///   cooldownSeconds: 600,
/// ));
///
/// await host.registerPlugin(plugin);
/// ```
class CustomNotificationPlugin extends SkotiqPlugin {
  PluginContext? _context;
  final List<NotificationRule> _rules = [];
  final Map<String, StreamSubscription> _subscriptions = {};

  /// Count of notifications sent since last enable
  int _notificationCount = 0;

  @override
  String get id => 'com.skotiq.notifications';

  @override
  String get name => 'Custom Notifications';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Monitors events and sends notifications when configurable '
      'conditions are met (e.g., high wind, low temperature, guiding lost)';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info(
      'Custom notification plugin loaded with ${_rules.length} rules',
    );
  }

  @override
  Future<void> onEnable() async {
    final context = _context;
    if (context == null) return;

    _notificationCount = 0;

    // Reset all cooldowns on enable
    for (final rule in _rules) {
      rule.resetCooldown();
    }

    // Subscribe to all unique event names in rules
    _rebuildSubscriptions();

    context.logger.info(
      'Notifications enabled with ${_rules.length} rules '
      'monitoring ${_subscriptions.length} event streams',
    );
  }

  @override
  Future<void> onDisable() async {
    _context?.logger.info(
      'Notifications disabled. Sent $_notificationCount notifications '
      'this session.',
    );

    await _cancelAllSubscriptions();
  }

  @override
  Future<void> onUnload() async {
    await _cancelAllSubscriptions();
    _rules.clear();
    _context = null;
  }

  /// Add a notification rule.
  ///
  /// If the plugin is currently enabled, the subscription is created
  /// immediately for the rule's event name.
  void addRule(NotificationRule rule) {
    _rules.add(rule);
    _context?.logger.info('Added notification rule: ${rule.name}');

    // If we're already enabled, rebuild subscriptions to pick up the new event
    if (_context != null && _subscriptions.isNotEmpty) {
      _rebuildSubscriptions();
    }
  }

  /// Remove a notification rule by name.
  ///
  /// Returns true if a rule was removed.
  bool removeRule(String ruleName) {
    final lengthBefore = _rules.length;
    _rules.removeWhere((r) => r.name == ruleName);
    if (_rules.length < lengthBefore) {
      _context?.logger.info('Removed notification rule: $ruleName');
      _rebuildSubscriptions();
      return true;
    }
    return false;
  }

  /// Get all configured rules (read-only view).
  List<NotificationRule> get rules => List.unmodifiable(_rules);

  /// Get the notification count for the current enabled session.
  int get notificationCount => _notificationCount;

  /// Rebuild event bus subscriptions based on current rules.
  void _rebuildSubscriptions() {
    final context = _context;
    if (context == null) return;

    // Cancel existing subscriptions
    _cancelAllSubscriptions();

    // Get unique event names from all rules
    final eventNames = _rules.map((r) => r.eventName).toSet();

    for (final eventName in eventNames) {
      _subscriptions[eventName] = context.eventBus
          .on(eventName)
          .listen((data) => _evaluateRules(eventName, data));
    }
  }

  /// Evaluate all rules that match the given event name.
  void _evaluateRules(String eventName, Map<String, dynamic> data) {
    final context = _context;
    if (context == null) return;

    final matchingRules = _rules.where((r) => r.eventName == eventName);

    for (final rule in matchingRules) {
      final message = rule.evaluate(data);
      if (message != null) {
        _sendNotification(rule.name, message, data);
      }
    }
  }

  /// Send a notification by emitting an event on the event bus.
  void _sendNotification(
    String ruleName,
    String message,
    Map<String, dynamic> sourceData,
  ) {
    final context = _context;
    if (context == null) return;

    _notificationCount++;

    context.logger.info('NOTIFICATION [$ruleName]: $message');

    context.eventBus.emit('plugin.notification', {
      'source': id,
      'rule': ruleName,
      'message': message,
      'level': 'warning',
      'timestamp': DateTime.now().toIso8601String(),
      'sourceData': sourceData,
    });
  }

  /// Cancel all active event subscriptions.
  Future<void> _cancelAllSubscriptions() async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }
}
