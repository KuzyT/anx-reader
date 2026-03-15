import 'dart:async';
import 'package:flutter/foundation.dart';

enum AiTranslationState {
  idle,
  translating,
  waitingRateLimit,
  error,
}

class AiLogEntry {
  final DateTime timestamp;
  final String message;
  final bool isError;
  final String? requestPayload;
  final String? responsePayload;

  AiLogEntry({
    required this.timestamp,
    required this.message,
    this.isError = false,
    this.requestPayload,
    this.responsePayload,
  });
}

class AiRequestStats {
  final DateTime timestamp;
  final int itemsCount;
  final bool isError;
  final int durationMs;
  final String modelName;

  AiRequestStats({
    required this.timestamp,
    required this.itemsCount,
    this.isError = false,
    this.durationMs = 0,
    this.modelName = '',
  });
}

class AiTranslationStatusService extends ChangeNotifier {
  static final AiTranslationStatusService _instance =
      AiTranslationStatusService._internal();

  factory AiTranslationStatusService() {
    return _instance;
  }

  AiTranslationStatusService._internal();

  AiTranslationState _state = AiTranslationState.idle;
  int _translatingCount = 0;
  final List<AiLogEntry> _logs = [];
  final List<AiRequestStats> _requestStats = [];
  static const int _maxLogs = 50;
  static const int _maxRequestStats = 200;
  String _lastErrorMessage = '';

  Timer? _durationTimer;
  int _translationDurationSec = 0;

  AiTranslationState get state => _state;
  int get translatingCount => _translatingCount;
  int get translationDurationSec => _translationDurationSec;
  List<AiLogEntry> get logs => List.unmodifiable(_logs);
  List<AiRequestStats> get requestStats => List.unmodifiable(_requestStats);
  String get lastErrorMessage => _lastErrorMessage;

  void startTranslating(int count) {
    _state = AiTranslationState.translating;
    _translatingCount = count;
    _stopTimer();
    _durationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _translationDurationSec += 10;
      notifyListeners();
    });
    notifyListeners();
  }

  void _stopTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _translationDurationSec = 0;
  }

  void setWaitingRateLimit() {
    _stopTimer();
    _state = AiTranslationState.waitingRateLimit;
    notifyListeners();
  }

  void setError(String error) {
    _stopTimer();
    _state = AiTranslationState.error;
    _lastErrorMessage = error;
    notifyListeners();
  }

  void setIdle() {
    _stopTimer();
    _state = AiTranslationState.idle;
    _translatingCount = 0;
    notifyListeners();
  }

  void addLog({
    required String message,
    bool isError = false,
    String? requestPayload,
    String? responsePayload,
  }) {
    _logs.add(AiLogEntry(
      timestamp: DateTime.now(),
      message: message,
      isError: isError,
      requestPayload: requestPayload,
      responsePayload: responsePayload,
    ));

    // Keep only last N logs to prevent memory leak
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    notifyListeners();
  }

  void addRequestStat({
    required int itemsCount,
    bool isError = false,
    int durationMs = 0,
    String modelName = '',
  }) {
    _requestStats.add(AiRequestStats(
      timestamp: DateTime.now(),
      itemsCount: itemsCount,
      isError: isError,
      durationMs: durationMs,
      modelName: modelName,
    ));
    if (_requestStats.length > _maxRequestStats) {
      _requestStats.removeAt(0);
    }
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    _requestStats.clear();
    notifyListeners();
  }
}
