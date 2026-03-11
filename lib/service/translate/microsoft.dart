import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _urlMicrosoft =
    'https://api-edge.cognitive.microsofttranslator.com/translate';
const _urlMicrosoftAuth = 'https://edge.microsoft.com/translate/auth';

/// Legacy Microsoft Translate provider using reverse-engineered Edge API.
/// Deprecated: Will be removed on 2026-03-01.
class MicrosoftTranslateProvider extends TranslateServiceProvider {
  @override
  TranslateService get service => TranslateService.microsoft;

  @override
  String getLabel(BuildContext context) =>
      L10n.of(context).translateMicrosoftLegacy;

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
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
    WidgetRef? ref,
  }) async* {
    try {
      yield "...";
      final token = await _getMicrosoftKey();

      final params = {
        'api-version': '3.0',
        'from': from == LangListEnum.auto ? '' : mapLanguageCode(from),
        'to': mapLanguageCode(to),
      };
      final body = [
        {'Text': text},
      ];
      final uri = Uri.parse(_urlMicrosoft).replace(queryParameters: params);
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

      final response = await Dio()
          .post(uri.toString(), data: body, options: Options(headers: headers));
      yield response.data[0]['translations'][0]['text'];
    } catch (e) {
      AnxLog.severe("Translate Microsoft Error: error=$e");
      yield* Stream.error(Exception(e));
    }
  }

  Future<String> _getMicrosoftKey() async {
    final response = await Dio().get(_urlMicrosoftAuth);
    String microsoftKey = response.data;
    return microsoftKey;
  }
}
