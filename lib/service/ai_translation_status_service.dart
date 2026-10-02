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

class _TrackedRequest {
  final int id;
  final int itemsCount;
  final String source;
  final DateTime startedAt;

  const _TrackedRequest({
    required this.id,
    required this.itemsCount,
    required this.source,
    required this.startedAt,
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
  int _nextRequestId = 1;
  final Map<int, _TrackedRequest> _activeRequests = {};
  final List<int> _legacyRequestIds = [];

  AiTranslationState get state => _state;
  int get translatingCount => _translatingCount;
  int get translationDurationSec => _translationDurationSec;
  int get activeRequestsCount => _activeRequests.length;
  List<AiLogEntry> get logs => List.unmodifiable(_logs);
  List<AiRequestStats> get requestStats => List.unmodifiable(_requestStats);
  String get lastErrorMessage => _lastErrorMessage;

  void _stopTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _translationDurationSec = 0;
  }

  void _ensureTimer() {
    if (_durationTimer != null) return;
    _durationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _translationDurationSec += 10;
      notifyListeners();
    });
  }

  void _updateStateFromActiveRequests() {
    if (_activeRequests.isEmpty) {
      _state = AiTranslationState.idle;
      _translatingCount = 0;
      _stopTimer();
    } else {
      _state = AiTranslationState.translating;
      _ensureTimer();
    }
  }

  int beginRequest({
    required int itemsCount,
    required String source,
    String? message,
  }) {
    final safeCount = itemsCount <= 0 ? 1 : itemsCount;
    final id = _nextRequestId++;
    _activeRequests[id] = _TrackedRequest(
      id: id,
      itemsCount: safeCount,
      source: source,
      startedAt: DateTime.now(),
    );
    _translatingCount += safeCount;
    _state = AiTranslationState.translating;
    _ensureTimer();

    if (message != null && message.trim().isNotEmpty) {
      addLog(message: message.trim());
      return id;
    }

    notifyListeners();
    return id;
  }

  void endRequest(
    int requestId, {
    bool isError = false,
    String? message,
    String? requestPayload,
    String? responsePayload,
    int? durationMs,
    String modelName = '',
  }) {
    final tracked = _activeRequests.remove(requestId);
    if (tracked == null) return;
    _legacyRequestIds.remove(requestId);

    _translatingCount -= tracked.itemsCount;
    if (_translatingCount < 0) _translatingCount = 0;

    final elapsedMs = durationMs ??
        DateTime.now().difference(tracked.startedAt).inMilliseconds;
    addRequestStat(
      itemsCount: tracked.itemsCount,
      isError: isError,
      durationMs: elapsedMs > 0 ? elapsedMs : 0,
      modelName: modelName.isEmpty ? tracked.source : modelName,
    );

    if (message != null && message.trim().isNotEmpty) {
      _updateStateFromActiveRequests();
      addLog(
        message: message.trim(),
        isError: isError,
        requestPayload: requestPayload,
        responsePayload: responsePayload,
      );
      return;
    }

    _updateStateFromActiveRequests();
    notifyListeners();
  }

  // Backward-compatible API (used by existing AI provider code)
  void startTranslating(int count) {
    final id = beginRequest(itemsCount: count, source: 'ai_translate');
    _legacyRequestIds.add(id);
  }

  void setWaitingRateLimit() {
    _state = AiTranslationState.waitingRateLimit;
    notifyListeners();
  }

  void setError(String error) {
    _state = AiTranslationState.error;
    _lastErrorMessage = error;
    notifyListeners();
  }

  void setIdle() {
    if (_legacyRequestIds.isNotEmpty) {
      final id = _legacyRequestIds.removeAt(0);
      endRequest(id);
      return;
    }
    _updateStateFromActiveRequests();
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
