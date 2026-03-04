import 'dart:convert';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:flutter/material.dart';

class AiTranslateProvider extends TranslateServiceProvider {
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
  @override
  Future<List<String>> translateBatch(
    List<String> texts,
    LangListEnum from,
    LangListEnum to,
  ) async {
    if (texts.isEmpty) return [];
    if (texts.length == 1) {
      // Single text — use standard translate
      final result = await this.translateTextOnly(texts[0], from, to);
      return [result];
    }

    try {
      final textsJson = jsonEncode(texts);
      final payload = generatePromptTranslateBatch(
        textsJson,
        mapLanguageCode(to),
        mapLanguageCode(from),
      );

      final messages = payload.buildMessages();

      // Collect the full AI response
      String fullResponse = '';
      await for (final chunk in aiGenerateStream(messages, regenerate: false)) {
        fullResponse = chunk;
      }

      // Parse JSON array from response
      final parsed = _parseJsonArrayFromResponse(fullResponse, texts.length);
      if (parsed != null) {
        return parsed;
      }

      // Fallback: if parsing fails, translate individually
      AnxLog.warning(
          'Batch translation JSON parse failed, falling back to individual. Response: $fullResponse');
      return await super.translateBatch(texts, from, to);
    } catch (e) {
      AnxLog.severe('Batch translation error: $e');
      // Fallback to individual translation
      return await super.translateBatch(texts, from, to);
    }
  }

  /// Try to extract a JSON array of strings from the AI response.
  List<String>? _parseJsonArrayFromResponse(
      String response, int expectedLength) {
    try {
      // Try to find JSON array in response (AI might add extra text)
      final trimmed = response.trim();

      // Try direct parse first
      final decoded = jsonDecode(trimmed);
      if (decoded is List && decoded.length == expectedLength) {
        return decoded.map((e) => e.toString()).toList();
      }

      // Try to extract JSON array from response using regex
      final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(trimmed);
      if (jsonMatch != null) {
        final extracted = jsonDecode(jsonMatch.group(0)!);
        if (extracted is List && extracted.length == expectedLength) {
          return extracted.map((e) => e.toString()).toList();
        }
      }
    } catch (_) {}
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
