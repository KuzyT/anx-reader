import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/word_wise.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _deeplApiUrl = 'https://api-free.deepl.com/v2/translate';

class DeepLTranslateProvider extends TranslateServiceProvider {
  DeepLTranslateProvider({Dio? client}) : _client = client ?? Dio();
  final Dio _client;
  @override
  TranslateService get service => TranslateService.deepl;

  /// DeepL uses uppercase language codes (e.g., ZH, EN, JA).
  @override
  String mapLanguageCode(LangListEnum lang) {
    const Map<String, String> codeMap = {
      'zh-CN': 'ZH',
      'zh-TW': 'ZH',
      'en': 'EN',
      'ja': 'JA',
      'de': 'DE',
      'fr': 'FR',
      'es': 'ES',
      'it': 'IT',
      'nl': 'NL',
      'pl': 'PL',
      'pt': 'PT',
      'ru': 'RU',
    };
    return codeMap[lang.code] ?? lang.code.toUpperCase();
  }

  @override
  String getLabel(BuildContext context) => L10n.of(context).translateDeepL;

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
    WidgetRef? ref,
  }) {
    return convertStreamToWidget(
      translateStream(text, from, to, contextText: contextText),
    );
  }

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
    WidgetRef? ref,
  }) async* {
    yield '...';
    final results = await translateBatch([text], from, to,
        contextText: contextText, ref: ref);
    if (results.single == '__ANX_RATE_LIMIT__') {
      throw StateError('RateLimitException(429)');
    }
    if (isTranslationFailure(results.single)) {
      throw const FormatException('Empty translation response');
    }
    yield results.single;
  }

  @override
  Future<List<String>> translateBatch(
      List<String> texts, LangListEnum from, LangListEnum to,
      {String level = 'full',
      String? pageInfo,
      String? contextText,
      WidgetRef? ref}) async {
    final config = getConfig();
    final key = config['api_key']?.toString() ?? '';
    if (key.isEmpty) throw StateError('Please set DeepL API Key in settings');
    final results = <String>[];
    for (final chunk in translationChunks(texts)) {
      try {
        final response = await _client.post(config['api_url'] ?? _deeplApiUrl,
            data: {
              'text': chunk,
              'target_lang': mapLanguageCode(to),
              if (from != LangListEnum.auto)
                'source_lang': mapLanguageCode(from),
              if (contextText != null && contextText.isNotEmpty)
                'context': contextText
            },
            options: Options(headers: {
              'Content-Type': 'application/json',
              'Authorization': 'DeepL-Auth-Key $key'
            }));
        final rows =
            response.data is Map ? response.data['translations'] : null;
        if (rows is! List) {
          throw const FormatException('DeepL API returned unexpected data');
        }
        results.addAll(orderedTranslations(
            rows, chunk.length, (row) => row['text'] as String));
      } catch (error) {
        final limited =
            error is DioException && error.response?.statusCode == 429;
        results.addAll(List.filled(
            chunk.length, limited ? '__ANX_RATE_LIMIT__' : '__ANX_RETRY__'));
      }
    }
    return results;
  }

  @override
  List<ConfigItem> getConfigItems(BuildContext context) {
    return [
      ConfigItem(
        key: 'tip',
        label: L10n.of(context).translateTip,
        type: ConfigItemType.tip,
        defaultValue: L10n.of(context).translateDeepLHelpText,
        link: 'https://anx.anxcye.com/docs/translate/deepl',
      ),
      ConfigItem(
        key: 'api_url',
        label: 'DeepL API URL',
        type: ConfigItemType.text,
        defaultValue: _deeplApiUrl,
      ),
      ConfigItem(
        key: 'api_key',
        label: 'DeepL API Key',
        description: L10n.of(navigatorKey.currentContext!).deeplKeyTip,
        type: ConfigItemType.password,
        defaultValue: '',
      ),
    ];
  }

  @override
  Map<String, dynamic> getConfig() {
    final config = Prefs().getTranslateServiceConfig(service);
    return config ?? {'api_key': '', 'api_url': _deeplApiUrl};
  }

  @override
  void saveConfig(Map<String, dynamic> config) {
    Prefs().saveTranslateServiceConfig(service, config);
  }
}
