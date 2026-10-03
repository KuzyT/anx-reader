import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/word_wise.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';

const _urlMicrosoftApi =
    'https://api.cognitive.microsofttranslator.com/translate';

class MicrosoftApiTranslateProvider extends TranslateServiceProvider {
  MicrosoftApiTranslateProvider({Dio? client}) : _client = client ?? Dio();
  final Dio _client;
  @override
  TranslateService get service => TranslateService.microsoftApi;

  @override
  String getLabel(BuildContext context) =>
      L10n.of(context).translateMicrosoftAzure;

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
    if (key.isEmpty) {
      throw StateError('Please set Microsoft API Key in settings');
    }
    final region = config['region']?.toString() ?? '';
    final results = <String>[];
    for (final chunk in translationChunks(texts)) {
      try {
        final response = await _client.post(_urlMicrosoftApi,
            queryParameters: {
              'api-version': '3.0',
              'to': mapLanguageCode(to),
              if (from != LangListEnum.auto) 'from': mapLanguageCode(from)
            },
            data: chunk.map((text) => {'Text': text}).toList(),
            options: Options(headers: {
              'Content-Type': 'application/json',
              'Ocp-Apim-Subscription-Key': key,
              if (region.isNotEmpty && region != 'global')
                'Ocp-Apim-Subscription-Region': region
            }));
        final rows = response.data;
        if (rows is! List) {
          throw const FormatException('Microsoft API returned unexpected data');
        }
        results.addAll(orderedTranslations(rows, chunk.length,
            (row) => row['translations'][0]['text'] as String));
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
        defaultValue: L10n.of(context).translateAzureHelpText,
        link: 'https://anx.anxcye.com/docs/translate/azure',
      ),
      ConfigItem(
        key: 'api_key',
        label: 'API Key',
        description: L10n.of(context).translateAzureApiKeyDescription,
        type: ConfigItemType.password,
        defaultValue: '',
      ),
      ConfigItem(
        key: 'region',
        label: 'Region',
        description: L10n.of(context).translateAzureRegionDescription,
        type: ConfigItemType.text,
        defaultValue: 'global',
      ),
    ];
  }

  @override
  Map<String, dynamic> getConfig() {
    final config = Prefs().getTranslateServiceConfig(service);
    return config ?? {'api_key': '', 'region': 'global'};
  }

  @override
  void saveConfig(Map<String, dynamic> config) {
    Prefs().saveTranslateServiceConfig(service, config);
  }
}
