import 'dart:convert';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
 import 'package:anx_reader/service/ai_translation_status_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  static void cancelTranslation() {
    if (_activeBatchRequest != null) {
      cancelActiveAiRequest();
      _activeBatchRequest = null;
      AiTranslationStatusService().setIdle();
    }
  }

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    WidgetRef? ref,
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
    WidgetRef? ref,
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
          in aiGenerateStream(messages, regenerate: false, ref: ref)) {
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
    String? pageInfo,
    WidgetRef? ref,
  }) async {
    dynamic messages;
    String promptText = '';
    String fullResponse = '';
    String retryPromptText = '';
    String retryResponse = '';

    // Concurrency control: Wait for any ongoing batch translation to finish
    while (_activeBatchRequest != null) {
      await _activeBatchRequest;
    }

    final completer = Completer<void>();
    _activeBatchRequest = completer.future;

    final statusService = AiTranslationStatusService();

    try {
      if (texts.isEmpty) return [];
      statusService.startTranslating(texts.length);

      if (texts.length == 1 && level == 'level0') {
        // Single text — use standard translate
        final result =
            await this.translateTextOnly(texts[0], from, to, ref: ref);
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
      promptText = messages.map((m) => m.contentAsString).join('\n');
      debugPrint('📨 [AI PROMPT] (${promptText.length} chars):\n$promptText');

      // Collect the full AI response with timing
      final stopwatch = Stopwatch()..start();
      await for (final chunk
          in aiGenerateStream(messages, regenerate: false, ref: ref)) {
        fullResponse = chunk;
      }
      stopwatch.stop();
      debugPrint(
          '📩 [AI RESPONSE] (${stopwatch.elapsed.inMilliseconds}ms, ${fullResponse.length} chars):\n$fullResponse');

      // Check for textual errors from AI like "Error: Rate limit reached. Try again later."
      if (fullResponse.contains('Cancelled by user') ||
          fullResponse.contains('cancelled by user')) {
        throw Exception('Cancelled by user or system');
      }

      final normalizedResponse = fullResponse.toLowerCase();
      final isRateLimit = normalizedResponse.contains('rate limit') ||
          normalizedResponse.contains('quota exceeded') ||
          RegExp(r'(^|\\D)429(\\D|$)').hasMatch(normalizedResponse);
      if (isRateLimit) {
        throw Exception('RateLimitException(429): $fullResponse');
      }
      if (normalizedResponse.startsWith('error:')) {
        throw Exception(fullResponse);
      }

      // Parse JSON array from response
      final parsed = _parseJsonArrayFromResponse(fullResponse, texts.length);
      if (parsed != null) {
        String logMessage =
            'Translated ${texts.length} items (${stopwatch.elapsed.inMilliseconds}ms)';
        if (pageInfo != null && pageInfo.isNotEmpty) {
          logMessage += ' [Pages: $pageInfo]';
        }

        statusService.addLog(
          message: logMessage,
          requestPayload: promptText,
          responsePayload: fullResponse,
        );

        statusService.addRequestStat(
          itemsCount: texts.length,
          durationMs: stopwatch.elapsed.inMilliseconds,
        );
        return parsed;
      }

      // Fallback: if parsing fails, throw Exception to log as error in catch block
      AnxLog.warning(
          'Batch translation JSON parse failed. Response: $fullResponse');
      throw Exception('Failed to parse JSON response');
    } catch (e) {
      final errorStr = e.toString();
      final normalizedError = errorStr.toLowerCase();
      if (errorStr.contains('Cancelled by user or system') ||
          errorStr.contains('cancelled by user')) {
        AnxLog.info('Batch translation cancelled by user or system.');
        AiTranslationStatusService().setIdle();
        return List.filled(texts.length, '__ANX_CANCELLED__');
      }

      AnxLog.severe('Batch translation error: $errorStr');
      final statusService = AiTranslationStatusService();
      final responseForDebug =
          fullResponse.trim().isNotEmpty ? fullResponse : errorStr;

      // Check for Rate Limit (429) and parse the retry duration if available
      if (normalizedError.contains('429') ||
          normalizedError.contains('rate limit') ||
          normalizedError.contains('quota exceeded')) {
        statusService.setWaitingRateLimit();
        final retryMatch =
            RegExp(r'retry in ([\d\.]+)s', caseSensitive: false)
                .firstMatch(errorStr);
        double delaySeconds = 60.0; // Default backoff
        if (retryMatch != null && retryMatch.group(1) != null) {
          delaySeconds = double.tryParse(retryMatch.group(1)!) ?? 60.0;
        }

        // Wait and perform exactly ONE retry
        AnxLog.info(
            'Rate limit hit. Waiting for ${delaySeconds.toStringAsFixed(1)} seconds before retrying batch...');
        debugPrint(
            '⏳ [RATE LIMIT] Waiting ${delaySeconds.toStringAsFixed(1)}s...');

        statusService.addLog(
          message:
              'Rate limit hit. Waiting ${delaySeconds.toStringAsFixed(1)}s...',
          isError: true,
          requestPayload: promptText.isNotEmpty ? promptText : null,
          responsePayload: responseForDebug,
        );

        statusService.addRequestStat(
          itemsCount: texts.length,
          isError: true,
        );

        AnxToast.show(
            'Rate limit exceeded. Retrying in ${delaySeconds.toInt()}s',
            duration: 3000);

        await Future.delayed(Duration(
            milliseconds:
                (delaySeconds * 1000).toInt() + 500)); // Add 500ms buffer

        statusService.startTranslating(texts.length);

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

          retryPromptText =
              retryMessages.map((m) => m.contentAsString).join('\n');
          retryResponse = '';
          await for (final chunk
              in aiGenerateStream(retryMessages, regenerate: false, ref: ref)) {
            retryResponse = chunk;
          }
          // Check for textual errors from AI like "Error: Rate limit reached. Try again later."
          final normalizedRetry = retryResponse.toLowerCase();
          final isRetryRateLimit = normalizedRetry.contains('rate limit') ||
              normalizedRetry.contains('quota exceeded') ||
              RegExp(r'(^|\\D)429(\\D|$)').hasMatch(normalizedRetry);
          if (isRetryRateLimit) {
            throw Exception('RateLimitException(429): $retryResponse');
          }
          if (normalizedRetry.startsWith('error:')) {
            throw Exception(retryResponse);
          }

          final parsedRetry =
              _parseJsonArrayFromResponse(retryResponse, texts.length);

          if (parsedRetry != null) {
            statusService.addLog(
              message: 'Retry: Translated ${texts.length} items',
              requestPayload:
                  retryMessages.map((m) => m.contentAsString).join('\n'),
              responsePayload: retryResponse,
            );

            statusService.addRequestStat(
              itemsCount: texts.length,
            );
            return parsedRetry;
          }

          throw Exception('Retry JSON parse failed: $retryResponse');
        } catch (retryErr) {
          AnxLog.severe('Batch translation retry also failed: $retryErr');
          statusService.setError('Retry failed');
          statusService.addLog(
            message: 'Retry failed',
            isError: true,
            requestPayload:
                retryPromptText.isNotEmpty ? retryPromptText : null,
            responsePayload:
                retryResponse.trim().isNotEmpty ? retryResponse : retryErr.toString(),
          );
          statusService.addRequestStat(
            itemsCount: texts.length,
            isError: true,
          );
          return List.filled(texts.length, '__ANX_RATE_LIMIT__');
        }
      } else {
        statusService.setError('Translation error');
        statusService.addLog(
          message: 'Translation error',
          isError: true,
          requestPayload: promptText.isNotEmpty ? promptText : null,
          responsePayload: responseForDebug,
        );
        statusService.addRequestStat(
          itemsCount: texts.length,
          isError: true,
        );
        return List.filled(texts.length, '__ANX_ERROR__');
      }

      // If we fall through to here
      return List.filled(texts.length, '__ANX_ERROR__');
    } finally {
      AiTranslationStatusService().setIdle();
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
