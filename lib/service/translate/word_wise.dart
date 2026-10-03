import 'dart:convert';
import 'package:anx_reader/models/vocabulary.dart';

final wordWiseTokenPattern =
    RegExp(r"[\p{L}\p{M}\p{N}]+(?:['‘’\-][\p{L}\p{M}\p{N}]+)*", unicode: true);
bool isTranslationFailure(String value) =>
    value.trim().isEmpty ||
    value.startsWith('__ANX_') ||
    RegExp(r'^(error:|translation error:|translation cancelled)',
            caseSensitive: false)
        .hasMatch(value.trim());

typedef _Hint = ({String translation, String? level, int count});

// Conservative native API batches fit all three providers' array/body limits.
Iterable<List<String>> translationChunks(List<String> texts) sync* {
  var chunk = <String>[], chars = 0;
  for (final text in texts) {
    if (chunk.isNotEmpty &&
        (chunk.length == 50 || chars + text.length > 4500)) {
      yield chunk;
      chunk = [];
      chars = 0;
    }
    chunk.add(text);
    chars += text.length;
  }
  if (chunk.isNotEmpty) yield chunk;
}

List<String> orderedTranslations(
        List<dynamic> rows, int count, String Function(dynamic) read) =>
    List.generate(count, (i) {
      try {
        final text = i < rows.length ? read(rows[i]) : '';
        return isTranslationFailure(text) ? '__ANX_RETRY__' : text;
      } catch (_) {
        return '__ANX_RETRY__';
      }
    });

/// Retains source characters and completed annotations while retrying missing words.
class WordWiseText {
  WordWiseText(this.source, String translated) {
    final segments =
        <({String original, String? translation, String? level})>[];
    try {
      final decoded = jsonDecode(translated);
      if (decoded is! List || decoded.isEmpty) throw const FormatException();
      for (final pair in decoded) {
        if (pair is! List ||
            pair.length < 2 ||
            pair[0] is! String ||
            pair[1] is! String) {
          throw const FormatException();
        }
        segments.add((
          original: pair[0] as String,
          translation: pair[1] as String,
          level: pair.length > 2 ? pair[2]?.toString() : null
        ));
      }
    } catch (_) {
      segments.clear();
      final pattern = RegExp(r'\[([^\[\]|]+)\|([^\[\]|]*)(?:\|([^\[\]|]*))?\]');
      var end = 0;
      for (final match in pattern.allMatches(translated)) {
        segments.add((
          original: translated.substring(end, match.start),
          translation: null,
          level: null
        ));
        segments.add(
            (original: match[1]!, translation: match[2]!, level: match[3]));
        end = match.end;
      }
      segments.add((
        original: translated.substring(end),
        translation: null,
        level: null
      ));
    }
    final reconstructed = segments.map((s) => s.original).join(' ');
    final sourceWords = tokens.map((m) => vocabularyWordKey(m[0]!)).toList();
    final reconstructedWords = wordWiseTokenPattern
        .allMatches(reconstructed)
        .map((m) => vocabularyWordKey(m[0]!))
        .toList();
    sourceMatches = sourceWords.length == reconstructedWords.length &&
        List.generate(sourceWords.length,
                (i) => sourceWords[i] == reconstructedWords[i])
            .every((same) => same);
    if (!sourceMatches) return;
    var index = 0;
    for (final segment in segments) {
      final count = wordWiseTokenPattern.allMatches(segment.original).length;
      if (segment.translation != null && count > 0) {
        _hints[index] = (
          translation: segment.translation!,
          level: segment.level,
          count: count
        );
      }
      index += count;
    }
  }
  WordWiseText._(this.source, this.sourceMatches, Map<int, _Hint> hints) {
    _hints.addAll(hints);
  }
  final String source;
  late final bool sourceMatches;
  final _hints = <int, _Hint>{};
  late final tokens = wordWiseTokenPattern.allMatches(source).toList();
  List<int> get _missingIndexes {
    final covered = <int>{};
    for (final entry in _hints.entries) {
      covered.addAll(List.generate(entry.value.count, (i) => entry.key + i));
    }
    return List.generate(tokens.length, (i) => i)
        .where((i) => !covered.contains(i))
        .toList();
  }

  List<String> get missingWords =>
      _missingIndexes.map((i) => tokens[i][0]!).toList();
  WordWiseText withLevels(Map<String, String> levels) => WordWiseText._(
      source,
      sourceMatches,
      _hints.map((index, hint) => MapEntry(index, (
            translation: hint.translation,
            level: levels[vocabularyWordKey(tokens[index][0]!)] ?? hint.level,
            count: hint.count
          ))));
  String get markedText {
    final result = StringBuffer();
    var cursor = 0;
    for (var i = 0; i < tokens.length; i++) {
      final hint = _hints[i];
      if (hint == null) continue;
      final end = tokens[i + hint.count - 1].end;
      result.write(source.substring(cursor, tokens[i].start));
      final word = source.substring(tokens[i].start, end);
      final translation = hint.translation
          .replaceAll('[', '(')
          .replaceAll(']', ')')
          .replaceAll('|', '/');
      result.write(
          '[$word|$translation${hint.level == null ? '' : '|${hint.level}'}]');
      cursor = end;
      i += hint.count - 1;
    }
    result.write(source.substring(cursor));
    return result.toString();
  }

  WordWiseText repair(List<String> results) {
    final updated = Map<int, _Hint>.of(_hints), missing = _missingIndexes;
    for (var i = 0; i < missing.length && i < results.length; i++) {
      if (isTranslationFailure(results[i])) continue;
      final word = tokens[missing[i]][0]!;
      final answer = WordWiseText(word, results[i]);
      if (answer.sourceMatches && answer.missingWords.isEmpty) {
        updated[missing[i]] = answer._hints[0]!;
      }
    }
    return WordWiseText._(source, sourceMatches, updated);
  }
}
