import 'dart:collection';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/ui_notification_provider.dart';
import 'logging_service.dart';

/// Error severity levels matching Rust EventSeverity
enum ErrorSeverity { info, warning, error, critical }

/// Convert to LogLevel for integration with logging service
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

/// Error categories for structured logging
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

/// Structured error entry with context
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

  /// Format for display
  String get displayMessage {
    final prefix = deviceType != null ? '[$deviceType] ' : '';
    return '$prefix$message';
  }

  /// Format for logging
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

/// Service for structured error logging and history
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

  /// Set the UI notification notifier for displaying errors to the user
  void setUiNotificationNotifier(UiNotificationNotifier notifier) {
    _uiNotificationNotifier = notifier;
  }

  /// Log a structured error
  void log(ErrorEntry entry) {
    // Add to history
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

    // Log to file via logging service if available
    _loggingService?.log(
      entry.severity.toLogLevel(),
      entry.message,
      source: '${entry.category.name}:${entry.operation}',
    );

    // Push to UI notifications for error and critical severity
    if (_uiNotificationNotifier != null) {
      final userFriendly = entry.userFriendly;
      switch (entry.severity) {
        case ErrorSeverity.error:
          _uiNotificationNotifier!.showError(
            userFriendly.fullMessage,
            title: entry.deviceType != null
                ? '${entry.deviceType} Error'
                : '${_categoryToTitle(entry.category)} Error',
          );
          break;
        case ErrorSeverity.critical:
          _uiNotificationNotifier!.showError(
            userFriendly.fullMessage,
            title: 'Critical: ${_categoryToTitle(entry.category)}',
            duration: const Duration(
              seconds: 15,
            ), // Persist longer for critical
          );
          break;
        case ErrorSeverity.warning:
          _uiNotificationNotifier!.showWarning(
            userFriendly.userMessage,
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

    // Notify listeners
    for (final listener in _listeners) {
      listener(entry);
    }
  }

  /// Convert error category to user-friendly title
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

  /// Convenience method for device errors
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

  /// Convenience method for imaging errors
  void logImagingError({
    required String operation,
    required String message,
    ErrorSeverity severity = ErrorSeverity.error,
    Map<String, dynamic>? context,
  }) {
    log(
      ErrorEntry(
        severity: severity,
        category: ErrorCategory.imaging,
        operation: operation,
        message: message,
        context: context,
      ),
    );
  }

  /// Convenience method for sequencer errors
  void logSequencerError({
    required String operation,
    required String message,
    ErrorSeverity severity = ErrorSeverity.error,
    Map<String, dynamic>? context,
  }) {
    log(
      ErrorEntry(
        severity: severity,
        category: ErrorCategory.sequencer,
        operation: operation,
        message: message,
        context: context,
      ),
    );
  }

  /// Convenience method for guiding errors
  void logGuidingError({
    required String operation,
    required String message,
    ErrorSeverity severity = ErrorSeverity.error,
    Map<String, dynamic>? context,
  }) {
    log(
      ErrorEntry(
        severity: severity,
        category: ErrorCategory.guiding,
        operation: operation,
        message: message,
        context: context,
      ),
    );
  }

  /// Log from exception with context
  void logException(
    Object error,
    StackTrace? stack, {
    required ErrorCategory category,
    required String operation,
    ErrorSeverity severity = ErrorSeverity.error,
    String? deviceType,
    String? deviceId,
    Map<String, dynamic>? context,
  }) {
    log(
      ErrorEntry.fromException(
        error,
        stack,
        category: category,
        operation: operation,
        severity: severity,
        deviceType: deviceType,
        deviceId: deviceId,
        context: context,
      ),
    );
  }

  /// Get recent errors
  List<ErrorEntry> getRecentErrors({int limit = 20}) {
    return _errorHistory.toList().reversed.take(limit).toList();
  }

  /// Get errors by category
  List<ErrorEntry> getErrorsByCategory(
    ErrorCategory category, {
    int limit = 20,
  }) {
    return _errorHistory
        .where((e) => e.category == category)
        .toList()
        .reversed
        .take(limit)
        .toList();
  }

  /// Get errors by severity
  List<ErrorEntry> getErrorsBySeverity(
    ErrorSeverity severity, {
    int limit = 20,
  }) {
    return _errorHistory
        .where((e) => e.severity == severity)
        .toList()
        .reversed
        .take(limit)
        .toList();
  }

  /// Clear error history
  void clearHistory() {
    _errorHistory.clear();
  }

  /// Add listener for new errors
  void addListener(void Function(ErrorEntry) listener) {
    _listeners.add(listener);
  }

  /// Remove listener
  void removeListener(void Function(ErrorEntry) listener) {
    _listeners.remove(listener);
  }

  /// Check if there are critical errors
  bool get hasCriticalErrors {
    return _errorHistory.any((e) => e.severity == ErrorSeverity.critical);
  }

  /// Get count of errors in the last N minutes
  int getErrorCountSince(Duration duration) {
    final cutoff = DateTime.now().subtract(duration);
    return _errorHistory.where((e) => e.timestamp.isAfter(cutoff)).length;
  }
}

/// Provider for the error service
final errorServiceProvider = Provider<ErrorService>((ref) {
  final service = ErrorService();
  final logging = ref.watch(loggingServiceProvider);
  service.setLoggingService(logging);

  final uiNotifier = ref.watch(uiNotificationProvider.notifier);
  service.setUiNotificationNotifier(uiNotifier);
  return service;
});

// User-Friendly Error Messages

/// Maps technical error messages to user-friendly messages
class UserFriendlyError {
  /// The original technical error
  final String technicalError;

  /// The user-friendly message
  final String userMessage;

  /// Optional suggestion for how to fix the problem
  final String? suggestion;

  /// Whether the error is recoverable
  final bool isRecoverable;

  const UserFriendlyError({
    required this.technicalError,
    required this.userMessage,
    this.suggestion,
    this.isRecoverable = true,
  });

  @override
  String toString() => userMessage;

  /// Full message including suggestion
  String get fullMessage {
    if (suggestion != null) {
      return '$userMessage\n\n$suggestion';
    }
    return userMessage;
  }
}

/// Converts technical error messages to user-friendly messages
class ErrorMessageMapper {
  /// Device connection error patterns
  static const Map<Pattern, UserFriendlyError> _deviceErrors = {
    'Device not found': UserFriendlyError(
      technicalError: 'Device not found',
      userMessage: 'The device could not be found.',
      suggestion:
          'Check that the device is powered on, connected, and the driver is installed.',
    ),
    'Connection refused': UserFriendlyError(
      technicalError: 'Connection refused',
      userMessage: 'Could not connect to the device.',
      suggestion:
          'Verify the device is on, connected via USB/network, and no other software is using it.',
    ),
    'Connection timed out': UserFriendlyError(
      technicalError: 'Connection timed out',
      userMessage: 'Connection to the device timed out.',
      suggestion: 'Check network settings and that the device is responding.',
    ),
    'Device already connected': UserFriendlyError(
      technicalError: 'Device already connected',
      userMessage: 'This device is already connected.',
      isRecoverable: true,
    ),
    'Device not connected': UserFriendlyError(
      technicalError: 'Device not connected',
      userMessage: 'The device is not connected.',
      suggestion: 'Connect to the device before performing this operation.',
    ),
    'ASCOM': UserFriendlyError(
      technicalError: 'ASCOM',
      userMessage: 'ASCOM driver error occurred.',
      suggestion:
          'Check that the ASCOM driver is installed and configured correctly.',
    ),
    'COM': UserFriendlyError(
      technicalError: 'COM',
      userMessage: 'Windows COM interface error.',
      suggestion: 'Try restarting the application or reconnecting the device.',
    ),
  };

  /// Imaging error patterns
  static const Map<Pattern, UserFriendlyError> _imagingErrors = {
    'Exposure cancelled': UserFriendlyError(
      technicalError: 'Exposure cancelled',
      userMessage: 'The exposure was cancelled.',
      isRecoverable: true,
    ),
    'Exposure failed': UserFriendlyError(
      technicalError: 'Exposure failed',
      userMessage: 'The exposure failed.',
      suggestion: 'Check camera connection and settings, then try again.',
    ),
    'Download failed': UserFriendlyError(
      technicalError: 'Download failed',
      userMessage: 'Failed to download image from camera.',
      suggestion: 'Check USB connection and try again.',
    ),
    'No image available': UserFriendlyError(
      technicalError: 'No image available',
      userMessage: 'No image is available.',
      suggestion: 'Take an exposure first.',
    ),
    'File write': UserFriendlyError(
      technicalError: 'File write',
      userMessage: 'Failed to save the image file.',
      suggestion:
          'Check that the save location is accessible and has sufficient disk space.',
    ),
    'Disk space': UserFriendlyError(
      technicalError: 'Disk space',
      userMessage: 'Insufficient disk space.',
      suggestion: 'Free up disk space or choose a different save location.',
    ),
  };

  /// Mount error patterns
  static const Map<Pattern, UserFriendlyError> _mountErrors = {
    'Slew failed': UserFriendlyError(
      technicalError: 'Slew failed',
      userMessage: 'Mount slew failed.',
      suggestion: 'Check that the mount is unparked and tracking is enabled.',
    ),
    'Target below horizon': UserFriendlyError(
      technicalError: 'Target below horizon',
      userMessage: 'The target is below the horizon.',
      suggestion: 'Wait until the target rises above the horizon.',
      isRecoverable: false,
    ),
    'Mount parked': UserFriendlyError(
      technicalError: 'Mount parked',
      userMessage: 'The mount is parked.',
      suggestion: 'Unpark the mount before slewing.',
    ),
    'Park failed': UserFriendlyError(
      technicalError: 'Park failed',
      userMessage: 'Failed to park the mount.',
      suggestion: 'Manually park the mount using the hand controller.',
    ),
    'Limit': UserFriendlyError(
      technicalError: 'Limit',
      userMessage: 'Mount has reached a limit.',
      suggestion:
          'The mount has reached its movement limits. Perform a meridian flip or reconfigure limits.',
    ),
  };

  /// Guiding error patterns
  static const Map<Pattern, UserFriendlyError> _guidingErrors = {
    'Guide star lost': UserFriendlyError(
      technicalError: 'Guide star lost',
      userMessage: 'Guide star was lost.',
      suggestion: 'Check guider focus and try selecting a brighter star.',
    ),
    'PHD2': UserFriendlyError(
      technicalError: 'PHD2',
      userMessage: 'PHD2 guiding error.',
      suggestion: 'Check PHD2 connection and guide camera settings.',
    ),
    'Settle timeout': UserFriendlyError(
      technicalError: 'Settle timeout',
      userMessage: 'Guiding failed to settle in time.',
      suggestion: 'Increase settle timeout or check for tracking issues.',
    ),
    'Calibration': UserFriendlyError(
      technicalError: 'Calibration',
      userMessage: 'Guiding calibration failed.',
      suggestion: 'Recalibrate guiding near the celestial equator.',
    ),
  };

  /// Plate solving error patterns
  static const Map<Pattern, UserFriendlyError> _plateSolveErrors = {
    'Plate solve failed': UserFriendlyError(
      technicalError: 'Plate solve failed',
      userMessage: 'Plate solving failed.',
      suggestion:
          'Ensure the mount is roughly pointed at the target. Try using a longer exposure or wider field hint.',
    ),
    'No solution': UserFriendlyError(
      technicalError: 'No solution',
      userMessage: 'Could not determine image location.',
      suggestion:
          'The image may be out of focus or pointing far from expected. Check focus and alignment.',
    ),
    'ASTAP': UserFriendlyError(
      technicalError: 'ASTAP',
      userMessage: 'ASTAP plate solver error.',
      suggestion:
          'Verify ASTAP is installed and the star database is downloaded.',
    ),
  };

  /// Convert a technical error to a user-friendly message
  static UserFriendlyError mapError(
    String technicalError, {
    ErrorCategory? category,
  }) {
    // Try category-specific patterns first
    if (category != null) {
      final categoryPatterns = _getCategoryPatterns(category);
      for (final entry in categoryPatterns.entries) {
        if (technicalError.toLowerCase().contains(
          entry.key.toString().toLowerCase(),
        )) {
          return entry.value;
        }
      }
    }

    // Try all patterns
    final allPatterns = [
      ..._deviceErrors.entries,
      ..._imagingErrors.entries,
      ..._mountErrors.entries,
      ..._guidingErrors.entries,
      ..._plateSolveErrors.entries,
    ];

    for (final entry in allPatterns) {
      if (technicalError.toLowerCase().contains(
        entry.key.toString().toLowerCase(),
      )) {
        return entry.value;
      }
    }

    // Default: return a generic user-friendly error
    return UserFriendlyError(
      technicalError: technicalError,
      userMessage: _cleanupErrorMessage(technicalError),
      suggestion: 'If the problem persists, check the logs for more details.',
    );
  }

  static Map<Pattern, UserFriendlyError> _getCategoryPatterns(
    ErrorCategory category,
  ) {
    switch (category) {
      case ErrorCategory.device:
        return _deviceErrors;
      case ErrorCategory.imaging:
        return _imagingErrors;
      case ErrorCategory.guiding:
        return _guidingErrors;
      case ErrorCategory.platesolve:
        return _plateSolveErrors;
      default:
        return {};
    }
  }

  /// Clean up a technical error message to be more readable
  static String _cleanupErrorMessage(String error) {
    // Remove common prefixes
    var cleaned = error
        .replaceAll(
          RegExp(r'^(Error:|Exception:|Failed:)\s*', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'^skotiq_\w+::\w+::\s*', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'Err\((.*)\)', caseSensitive: false), r'$1');

    // Capitalize first letter
    if (cleaned.isNotEmpty) {
      cleaned = cleaned[0].toUpperCase() + cleaned.substring(1);
    }

    // Ensure it ends with a period
    if (!cleaned.endsWith('.') &&
        !cleaned.endsWith('!') &&
        !cleaned.endsWith('?')) {
      cleaned += '.';
    }

    return cleaned;
  }

  /// Get a user-friendly message from an exception
  static UserFriendlyError fromException(
    Object error, {
    ErrorCategory? category,
  }) {
    return mapError(error.toString(), category: category);
  }
}

/// Extension to add user-friendly message methods to ErrorEntry
extension ErrorEntryUserFriendly on ErrorEntry {
  /// Get a user-friendly version of this error
  UserFriendlyError get userFriendly {
    return ErrorMessageMapper.mapError(message, category: category);
  }
}
