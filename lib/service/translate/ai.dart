import 'dart:convert';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:flutter/material.dart';
import 'dart:async';

class AiTranslateProvider extends TranslateServiceProvider {
  static Future<void>? _activeBatchRequest;

  @override
  TranslateService get service => TranslateService.ai;

  @override
  String getLabel(BuildContext context) => L10n.of(context).navBarAI;

  /// AI translation uses native language names (e.g., "简体中文", "English")
  /// instead of ISO codes for better prompt understanding.
  @override
  String mapLanguageCode(LangListEnum lang) => lang.nativeName;

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
  }) {
    final prompt = generatePromptTranslate(
      text,
      mapLanguageCode(to),
      mapLanguageCode(from),
      contextText: contextText,
    );

    return AiStream(
      prompt: prompt,
      regenerate: true,
    );
  }

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
  }) async* {
    try {
      final payload = generatePromptTranslate(
        text,
        mapLanguageCode(to),
        mapLanguageCode(from),
        contextText: contextText,
      );

      final messages = payload.buildMessages();

      await for (final result
          in aiGenerateStream(messages, regenerate: false)) {
        yield result;
      }
    } catch (e) {
      yield L10n.of(navigatorKey.currentContext!).translateError + e.toString();
    }
  }

  /// Batch translate: sends all texts in one AI request, expects JSON array response.
  /// For level0: sentence-level translation (JSON array of strings).
  /// For A1-C2: word-level translation (JSON array of word pairs).
  @override
  Future<List<String>> translateBatch(
    List<String> texts,
    LangListEnum from,
    LangListEnum to, {
    String level = 'level0',
  }) async {
    dynamic messages;

    // Concurrency control: Wait for any ongoing batch translation to finish
    while (_activeBatchRequest != null) {
      await _activeBatchRequest;
    }

    final completer = Completer<void>();
    _activeBatchRequest = completer.future;

    try {
      if (texts.isEmpty) return [];
      if (texts.length == 1 && level == 'level0') {
        // Single text — use standard translate
        final result = await this.translateTextOnly(texts[0], from, to);
        return [result];
      }

      final textsJson = jsonEncode(texts);
      late PromptTemplatePayload payload;

      if (level != 'level0') {
        // Word-level translation with word markers for interlinear mode
        debugPrint(
            '🎯 [TRANSLATE LEVEL] Using WORD-LEVEL prompt for level=$level');
        payload = generatePromptTranslateBatchWordLevel(
          textsJson,
          mapLanguageCode(to),
          mapLanguageCode(from),
          level,
        );
      } else {
        // Sentence-level translation for level0
        debugPrint(
            '🎯 [TRANSLATE LEVEL] Using SENTENCE-LEVEL prompt for level0');
        payload = generatePromptTranslateBatch(
          textsJson,
          mapLanguageCode(to),
          mapLanguageCode(from),
        );
      }

      messages = payload.buildMessages();

      // Log the full prompt being sent
      final promptText = messages.map((m) => m.contentAsString).join('\n');
      debugPrint('📨 [AI PROMPT] (${promptText.length} chars):\n$promptText');

      // Collect the full AI response with timing
      final stopwatch = Stopwatch()..start();
      String fullResponse = '';
      await for (final chunk
          in aiGenerateStream(messages, regenerate: false, temperature: 0.0)) {
        fullResponse = chunk;
      }
      stopwatch.stop();
      debugPrint(
          '📩 [AI RESPONSE] (${stopwatch.elapsed.inMilliseconds}ms, ${fullResponse.length} chars):\n$fullResponse');

      // Parse JSON array from response
      final parsed = _parseJsonArrayFromResponse(fullResponse, texts.length);
      if (parsed != null) {
        return parsed;
      }

      // Check for textual errors from AI like "Error: Rate limit reached. Try again later."
      if (fullResponse.contains('Rate limit') ||
          fullResponse.contains('429') ||
          fullResponse.contains('Quota exceeded')) {
        throw Exception('RateLimitException(429): $fullResponse');
      }

      // Fallback: if parsing fails, translate individually
      AnxLog.warning(
          'Batch translation JSON parse failed. Response: $fullResponse');
      return []; // Return empty instead of falling back to individual to save quota
    } catch (e) {
      final errorStr = e.toString();
      AnxLog.severe('Batch translation error: $errorStr');

      // Check for Rate Limit (429) and parse the retry duration if available
      if (errorStr.contains('429') ||
          errorStr.contains('Rate limit') ||
          errorStr.contains('Quota exceeded')) {
        final retryMatch = RegExp(r'retry in ([\d\.]+)s').firstMatch(errorStr);
        double delaySeconds = 60.0; // Default backoff
        if (retryMatch != null && retryMatch.group(1) != null) {
          delaySeconds = double.tryParse(retryMatch.group(1)!) ?? 60.0;
        }

        // Wait and perform exactly ONE retry
        AnxLog.info(
            'Rate limit hit. Waiting for ${delaySeconds.toStringAsFixed(1)} seconds before retrying batch...');
        debugPrint(
            '⏳ [RATE LIMIT] Waiting ${delaySeconds.toStringAsFixed(1)}s...');

        AnxToast.show(
            'Rate limit exceeded. Retrying in ${delaySeconds.toInt()}s',
            duration: 3000);

        await Future.delayed(Duration(
            milliseconds:
                (delaySeconds * 1000).toInt() + 500)); // Add 500ms buffer

        try {
          debugPrint('🔄 [RETRYING] Retrying batch translation after delay...');
          // RE-BUILD messages for retry
          final textsJsonRetry = jsonEncode(texts);
          late PromptTemplatePayload payloadRetry;
          if (level != 'level0') {
            payloadRetry = generatePromptTranslateBatchWordLevel(textsJsonRetry,
                mapLanguageCode(to), mapLanguageCode(from), level);
          } else {
            payloadRetry = generatePromptTranslateBatch(
                textsJsonRetry, mapLanguageCode(to), mapLanguageCode(from));
          }
          final retryMessages = payloadRetry.buildMessages();

          String retryResponse = '';
          await for (final chunk
              in aiGenerateStream(retryMessages, regenerate: false)) {
            retryResponse = chunk;
          }
          final parsedRetry =
              _parseJsonArrayFromResponse(retryResponse, texts.length);
          if (parsedRetry != null) {
            return parsedRetry;
          }
        } catch (retryErr) {
          AnxLog.severe('Batch translation retry also failed: $retryErr');
        }
      }

      // If we fall through to here
      return [];
    } finally {
      // Release the lock for the next request in queue
      _activeBatchRequest = null;
      completer.complete();
    }
  }

  /// Extracts a JSON array from a potentially messy text assuming the array contains translated strings
  /// serialized back to JSON string for JS to parse.
  List<String>? _parseJsonArrayFromResponse(
      String response, int expectedLength) {
    try {
      // Strip markdown code fences if present (```json ... ```)
      String cleaned = response.trim();
      final fenceRegex = RegExp(r'```(?:json)?\s*\n?([\s\S]*?)\n?\s*```');
      final fenceMatch = fenceRegex.firstMatch(cleaned);
      if (fenceMatch != null) {
        cleaned = fenceMatch.group(1)!.trim();
      }

      debugPrint('📋 [BATCH PARSE] Cleaned response:\n$cleaned');

      List<dynamic>? outerArray;

      // Try direct parse first
      try {
        final decoded = jsonDecode(cleaned);
        if (decoded is List && decoded.length == expectedLength) {
          outerArray = decoded;
        }
      } catch (_) {}

      // Try to extract JSON array from response using regex
      if (outerArray == null) {
        final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(cleaned);
        if (jsonMatch != null) {
          try {
            final extracted = jsonDecode(jsonMatch.group(0)!);
            if (extracted is List && extracted.length == expectedLength) {
              outerArray = extracted;
            }
          } catch (_) {}
        }
      }

      if (outerArray != null) {
        // Check if this is word-pair format or flat string format
        final firstElement = outerArray[0];
        if (firstElement is List) {
          // Word-pair format: [[word, translation], ...] — serialize each element
          debugPrint('📋 [BATCH PARSE] Word-pair format detected');
          return outerArray.map((e) => jsonEncode(e)).toList();
        } else if (firstElement is String) {
          // Flat string format (fallback from AI)
          debugPrint('📋 [BATCH PARSE] Flat string format detected');
          return outerArray.map((e) => e.toString()).toList();
        }
      }

      debugPrint('📋 [BATCH PARSE] Failed to parse response');
    } catch (e) {
      debugPrint('📋 [BATCH PARSE] Parse error: $e');
    }
    return null;
  }

  @override
  List<ConfigItem> getConfigItems(BuildContext context) {
    return [
      ConfigItem(
        key: 'tip',
        label: 'Tip',
        type: ConfigItemType.tip,
        defaultValue:
            L10n.of(navigatorKey.currentContext!).settingsTranslateAiTip,
      ),
    ];
  }
}
