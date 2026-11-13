import 'dart:collection';
import 'dart:developer' as developer;
import '../errors/error_text.dart';
import '../providers/ui_notification_provider.dart';
import 'logging_service.dart';

/// Error severity levels matching Rust EventSeverity
enum ErrorSeverity { info, warning, error, critical }

extension ErrorSeverityExtension on ErrorSeverity {
  LogLevel toLogLevel() {
    switch (this) {
      case ErrorSeverity.info:
        return LogLevel.info;
      case ErrorSeverity.warning:
        return LogLevel.warning;
      case ErrorSeverity.error:
        return LogLevel.error;
      case ErrorSeverity.critical:
        return LogLevel.critical;
    }
  }
}

enum ErrorCategory {
  device,
  imaging,
  sequencer,
  guiding,
  platesolve,
  storage,
  network,
  system,
  unknown,
}

class ErrorEntry {
  final DateTime timestamp;
  final ErrorSeverity severity;
  final ErrorCategory category;
  final String operation;
  final String message;
  final String? deviceType;
  final String? deviceId;
  final String? stackTrace;
  final Map<String, dynamic>? context;

  ErrorEntry({
    required this.severity,
    required this.category,
    required this.operation,
    required this.message,
    this.deviceType,
    this.deviceId,
    this.stackTrace,
    this.context,
  }) : timestamp = DateTime.now();

  /// Create from exception with automatic stack trace
  factory ErrorEntry.fromException(
    Object error,
    StackTrace? stack, {
    required ErrorCategory category,
    required String operation,
    ErrorSeverity severity = ErrorSeverity.error,
    String? deviceType,
    String? deviceId,
    Map<String, dynamic>? context,
  }) {
    return ErrorEntry(
      severity: severity,
      category: category,
      operation: operation,
      message: error.toString(),
      deviceType: deviceType,
      deviceId: deviceId,
      stackTrace: stack?.toString(),
      context: context,
    );
  }

  String get displayMessage {
    final prefix = deviceType != null ? '[$deviceType] ' : '';
    return '$prefix$message';
  }

  String get logMessage {
    final buffer = StringBuffer();
    buffer.write('[${severity.name.toUpperCase()}]');
    buffer.write('[${category.name}]');
    buffer.write(' $operation: $message');
    if (deviceType != null) buffer.write(' (device: $deviceType)');
    if (deviceId != null) buffer.write(' (id: $deviceId)');
    if (context != null && context!.isNotEmpty) {
      buffer.write(' context: $context');
    }
    return buffer.toString();
  }

  @override
  String toString() => logMessage;
}

class ErrorService {
  static final ErrorService _instance = ErrorService._internal();
  factory ErrorService() => _instance;
  ErrorService._internal();

  static const int _maxHistorySize = 100;
  final Queue<ErrorEntry> _errorHistory = Queue<ErrorEntry>();
  final List<void Function(ErrorEntry)> _listeners = [];
  LoggingService? _loggingService;
  UiNotificationNotifier? _uiNotificationNotifier;

  /// Set the logging service for file output integration
  void setLoggingService(LoggingService service) {
    _loggingService = service;
  }

  void setUiNotificationNotifier(UiNotificationNotifier notifier) {
    _uiNotificationNotifier = notifier;
  }

  void log(ErrorEntry entry) {
    _errorHistory.add(entry);
    while (_errorHistory.length > _maxHistorySize) {
      _errorHistory.removeFirst();
    }

    // Print to debug console
    developer.log(
      entry.logMessage,
      name: 'ErrorService',
      level: entry.severity.toLogLevel().index * 200 + 500,
    );

    _loggingService?.log(
      entry.severity.toLogLevel(),
      entry.message,
      source: '${entry.category.name}:${entry.operation}',
    );

    // Push to UI notifications for error and critical severity
    if (_uiNotificationNotifier != null) {
      final text = describeError(
        entry.message,
        domain: switch (entry.category) {
          ErrorCategory.device => ErrorDomain.device,
          ErrorCategory.imaging => ErrorDomain.imaging,
          ErrorCategory.guiding => ErrorDomain.guiding,
          ErrorCategory.platesolve => ErrorDomain.plateSolve,
          _ => null,
        },
      );
      switch (entry.severity) {
        case ErrorSeverity.error:
          _uiNotificationNotifier!.showError(
            text.full,
            title: entry.deviceType != null
                ? '${entry.deviceType} Error'
                : '${_categoryToTitle(entry.category)} Error',
          );
          break;
        case ErrorSeverity.critical:
          _uiNotificationNotifier!.showError(
            text.full,
            title: 'Critical: ${_categoryToTitle(entry.category)}',
            duration: const Duration(
              seconds: 15,
            ), // Persist longer for critical
          );
          break;
        case ErrorSeverity.warning:
          _uiNotificationNotifier!.showWarning(
            text.message,
            title: entry.deviceType != null
                ? '${entry.deviceType} Warning'
                : '${_categoryToTitle(entry.category)} Warning',
          );
          break;
        case ErrorSeverity.info:
          // Info level doesn't push to UI notifications
          break;
      }
    }

    for (final listener in _listeners) {
      listener(entry);
    }
  }

  String _categoryToTitle(ErrorCategory category) {
    switch (category) {
      case ErrorCategory.device:
        return 'Device';
      case ErrorCategory.imaging:
        return 'Imaging';
      case ErrorCategory.sequencer:
        return 'Sequence';
      case ErrorCategory.guiding:
        return 'Guiding';
      case ErrorCategory.platesolve:
        return 'Plate Solve';
      case ErrorCategory.storage:
        return 'Storage';
      case ErrorCategory.network:
        return 'Network';
      case ErrorCategory.system:
        return 'System';
      case ErrorCategory.unknown:
        return 'Error';
    }
  }

  void logDeviceError({
    required String operation,
    required String message,
    required String deviceType,
    String? deviceId,
    ErrorSeverity severity = ErrorSeverity.error,
    Map<String, dynamic>? context,
  }) {
    log(
      ErrorEntry(
        severity: severity,
        category: ErrorCategory.device,
        operation: operation,
        message: message,
        deviceType: deviceType,
        deviceId: deviceId,
        context: context,
      ),
    );
  }

  void addListener(void Function(ErrorEntry) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(ErrorEntry) listener) {
    _listeners.remove(listener);
  }

  bool get hasCriticalErrors {
    return _errorHistory.any((e) => e.severity == ErrorSeverity.critical);
  }

}
