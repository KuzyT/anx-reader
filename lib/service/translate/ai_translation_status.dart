import 'package:flutter/material.dart';

enum AiTranslationState {
  idle,
  translating,
  waiting,
  error,
}

class AiLogEntry {
  final DateTime timestamp;
  final String prompt;
  final String response;
  final bool isError;
  final String errorMessage;

  AiLogEntry({
    required this.timestamp,
    required this.prompt,
    required this.response,
    this.isError = false,
    this.errorMessage = '',
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
  String _message = '';
  final List<AiLogEntry> _logs = [];
  static const int _maxLogs = 50;

  AiTranslationState get state => _state;
  String get message => _message;
  List<AiLogEntry> get logs => List.unmodifiable(_logs);

  void setTranslating(int textCount) {
    _state = AiTranslationState.translating;
    _message = 'Translating $textCount item(s)...';
    notifyListeners();
  }

  void setWaiting(int seconds) {
    _state = AiTranslationState.waiting;
    _message = 'Rate limit. Waiting $seconds s...';
    notifyListeners();
  }

  void setError(String error) {
    _state = AiTranslationState.error;
    _message = 'Error: $error';
    notifyListeners();
  }

  void setIdle() {
    _state = AiTranslationState.idle;
    _message = '';
    notifyListeners();
  }

  void addLog(String prompt, String response,
      {bool isError = false, String errorMessage = ''}) {
    _logs.insert(
      0,
      AiLogEntry(
        timestamp: DateTime.now(),
        prompt: prompt,
        response: response,
        isError: isError,
        errorMessage: errorMessage,
      ),
    );
    if (_logs.length > _maxLogs) {
      _logs.removeLast();
    }
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
}
