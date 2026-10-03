import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/word_wise.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';

const _urlGoogleApi =
    'https://translation.googleapis.com/language/translate/v2';

class GoogleApiTranslateProvider extends TranslateServiceProvider {
  GoogleApiTranslateProvider({Dio? client}) : _client = client ?? Dio();
  final Dio _client;
  @override
  TranslateService get service => TranslateService.googleApi;

  @override
  String getLabel(BuildContext context) =>
      L10n.of(context).translateGoogleCloud;

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
    final key = getConfig()['api_key']?.toString() ?? '';
    if (key.isEmpty) throw StateError('Please set Google API Key in settings');
    final results = <String>[];
    for (final chunk in translationChunks(texts)) {
      try {
        final response = await _client.post(_urlGoogleApi, queryParameters: {
          'key': key
        }, data: {
          'q': chunk,
          'target': mapLanguageCode(to),
          'format': 'text',
          if (from != LangListEnum.auto) 'source': mapLanguageCode(from)
        });
        final data = response.data;
        final rows = data is Map && data['data'] is Map
            ? data['data']['translations']
            : null;
        if (rows is! List) {
          throw const FormatException('Google API returned unexpected data');
        }
        results.addAll(orderedTranslations(
            rows, chunk.length, (row) => row['translatedText'] as String));
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
        defaultValue: L10n.of(context).translateGoogleHelpText,
        link: 'https://anx.anxcye.com/docs/translate/google',
      ),
      ConfigItem(
        key: 'api_key',
        label: 'API Key',
        description: L10n.of(context).translateGoogleApiKeyDescription,
        type: ConfigItemType.password,
        defaultValue: '',
      ),
    ];
  }

  @override
  Map<String, dynamic> getConfig() {
    final config = Prefs().getTranslateServiceConfig(service);
    return config ?? {'api_key': ''};
  }

  @override
  void saveConfig(Map<String, dynamic> config) {
    Prefs().saveTranslateServiceConfig(service, config);
  }
}
