import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Service for managing background work and keeping the server alive
class BackgroundWorkService {
  static final BackgroundWorkService _instance = BackgroundWorkService._internal();

  bool _isWakeLockEnabled = false;
  bool _isBackgroundTasksRunning = false;
  Timer? _healthCheckTimer;
  Timer? _logRotationTimer;

  factory BackgroundWorkService() {
    return _instance;
  }

  BackgroundWorkService._internal();

  /// Initialize background work services
  Future<void> initialize() async {
    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Initializing background work services');
    }

    if (Platform.isAndroid) {
      await _initializeAndroidBackgroundProcessing();
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await _initializeDesktopBackgroundProcessing();
    }
  }

  /// Initialize Android-specific background processing
  Future<void> _initializeAndroidBackgroundProcessing() async {
    try {
      // Enable wake lock to prevent device from sleeping
      await enableWakeLock();

      // Start periodic health checks
      _startHealthCheckTimer();

      _isBackgroundTasksRunning = true;
      if (kDebugMode) {
        debugPrint('[BackgroundWorkService] Android background processing initialized');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[BackgroundWorkService] Failed to initialize Android background: $e');
      }
    }
  }

  /// Initialize desktop-specific background processing
  Future<void> _initializeDesktopBackgroundProcessing() async {
    try {
      // Start periodic health checks
      _startHealthCheckTimer();

      // Start log rotation timer
      _startLogRotationTimer();

      _isBackgroundTasksRunning = true;
      if (kDebugMode) {
        debugPrint('[BackgroundWorkService] Desktop background processing initialized');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[BackgroundWorkService] Failed to initialize desktop background: $e');
      }
    }
  }

  /// Enable wake lock to prevent device sleep (Android only)
  Future<void> enableWakeLock() async {
    if (_isWakeLockEnabled) {
      return;
    }

    try {
      if (Platform.isAndroid) {
        await WakelockPlus.enable();
        _isWakeLockEnabled = true;
        if (kDebugMode) {
          debugPrint('[BackgroundWorkService] Wake lock enabled');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[BackgroundWorkService] Failed to enable wake lock: $e');
      }
    }
  }

  /// Disable wake lock
  Future<void> disableWakeLock() async {
    if (!_isWakeLockEnabled) {
      return;
    }

    try {
      if (Platform.isAndroid) {
        await WakelockPlus.disable();
        _isWakeLockEnabled = false;
        if (kDebugMode) {
          debugPrint('[BackgroundWorkService] Wake lock disabled');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[BackgroundWorkService] Failed to disable wake lock: $e');
      }
    }
  }

  /// Start periodic health check timer
  void _startHealthCheckTimer() {
    if (_healthCheckTimer != null) {
      return;
    }

    _healthCheckTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) {
        _performHealthCheck();
      },
    );

    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Health check timer started');
    }
  }

  /// Perform health check to ensure server is still running
  void _performHealthCheck() {
    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Performing health check at ${DateTime.now()}');
    }
    // This can be extended to verify server status, reconnect clients, etc.
  }

  /// Start log rotation timer (desktop platforms)
  void _startLogRotationTimer() {
    if (_logRotationTimer != null) {
      return;
    }

    _logRotationTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) {
        _rotateLogs();
      },
    );

    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Log rotation timer started');
    }
  }

  /// Rotate logs to prevent them from growing too large
  void _rotateLogs() {
    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Log rotation performed at ${DateTime.now()}');
    }
    // This can be extended to implement actual log rotation
  }

  /// Check if background tasks are running
  bool get isBackgroundTasksRunning => _isBackgroundTasksRunning;

  /// Check if wake lock is enabled
  bool get isWakeLockEnabled => _isWakeLockEnabled;

  /// Shutdown background work services
  Future<void> shutdown() async {
    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Shutting down background work services');
    }

    // Cancel timers
    _healthCheckTimer?.cancel();
    _logRotationTimer?.cancel();

    // Disable wake lock
    await disableWakeLock();

    _isBackgroundTasksRunning = false;
    if (kDebugMode) {
      debugPrint('[BackgroundWorkService] Background work services shutdown complete');
    }
  }
}
