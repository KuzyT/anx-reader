import 'package:anx_reader/dao/translation_cache.dart';
import 'package:anx_reader/service/translate/word_wise.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/microsoft_api.dart';
import 'package:anx_reader/service/translate/google_api.dart';
import 'package:anx_reader/service/translate/deepl.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'translation_compatibility_test.dart' show RecordingDefaultProvider;
import 'package:anx_reader/service/tts/system_tts.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:flutter/services.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';

class BatchAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  bool short = false;
  int? failFrom;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    final body = options.data;
    final count =
        body is List ? body.length : (body['q'] ?? body['text']).length;
    final rows = List.generate(
        short ? count - 1 : count,
        (i) => options.uri.host.contains('microsoft')
            ? {
                'translations': [
                  {'text': 't$i'}
                ]
              }
            : options.uri.host.contains('google')
                ? {'translatedText': 't$i'}
                : {'text': 't$i'});
    final data = options.uri.host.contains('microsoft')
        ? rows
        : options.uri.host.contains('google')
            ? {
                'data': {'translations': rows}
              }
            : {'translations': rows};
    return ResponseBody.fromString(jsonEncode(data),
        failFrom != null && requests.length >= failFrom! ? 429 : status,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

class BoundedProvider extends RecordingDefaultProvider {
  int active = 0, maximum = 0;
  @override
  Future<String> translateTextOnly(
      String text, LangListEnum from, LangListEnum to,
      {String? contextText, bool isFullText = false, dynamic ref}) async {
    active++;
    if (active > maximum) maximum = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
    if (text == 'bad') throw StateError('fixture failure');
    return text;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('word prompt requires explicit skips and safely includes repair context',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    final payload = generatePromptTranslateBatchWordLevel(
        '["a"]', 'Russian', 'Portuguese', 'a1',
        contextText: 'a {sentence}');
    final text = payload
        .buildMessages()
        .map((message) => message.contentAsString)
        .join('\n');
    expect(text, contains('[word||0]'));
    expect(text, contains('a {sentence}'));
    expect(text, contains('annotate every word'));
  });
  test('explicit word pronunciation never advances book narration', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    const channel = MethodChannel('flutter_tts');
    Prefs().setTtsVoiceModel('system', 'fixture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        channel, (call) async => call.method == 'getVoices' ? [] : 1);
    var next = 0;
    final tts = SystemTts();
    await tts.init(() {}, () {
      next++;
      return '';
    }, () => '');
    tts.updateTtsState(TtsStateEnum.playing);
    await tts.speakWithVoice('olá', 'fixture');
    expect(next, 0);
    final previous = Completer<int>(), started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getVoices') return [];
      if (call.method == 'speak' &&
          (call.arguments is Map ? call.arguments['text'] : call.arguments) ==
              'chapter') {
        started.complete();
        return previous.future;
      }
      return 1;
    });
    final chapter = tts.speak(content: 'chapter');
    await started.future;
    await tts.speakWithVoice('olá', 'fixture');
    previous.complete(1);
    await chapter;
    expect(next, 0,
        reason:
            'Late chapter speech cannot advance after one-shot pronunciation starts');
    await tts.stop();
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
      'native APIs send arrays, retain order and mark short responses retryable',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    for (final kind in [
      TranslateService.microsoftApi,
      TranslateService.googleApi,
      TranslateService.deepl
    ]) {
      Prefs().saveTranslateServiceConfig(
          kind, {'api_key': 'fixture', 'region': 'global'});
      final adapter = BatchAdapter(), client = Dio();
      client.httpClientAdapter = adapter;
      final TranslateServiceProvider provider = switch (kind) {
        TranslateService.microsoftApi =>
          MicrosoftApiTranslateProvider(client: client),
        TranslateService.googleApi =>
          GoogleApiTranslateProvider(client: client),
        _ => DeepLTranslateProvider(client: client),
      };
      Future<List<String>> run() => provider.translateBatch(
          ['olá', 'mundo'], LangListEnum.portuguese, LangListEnum.russian);
      expect(await run(), ['t0', 't1']);
      expect(adapter.requests.length, 1);
      adapter.short = true;
      expect(await run(), ['t0', '__ANX_RETRY__']);
      adapter.status = 429;
      expect(await run(), ['__ANX_RATE_LIMIT__', '__ANX_RATE_LIMIT__']);
      adapter.status = 200;
      adapter.short = false;
      adapter.requests.clear();
      adapter.failFrom = 2;
      final large = await provider.translateBatch(List.filled(80, 'olá'),
          LangListEnum.portuguese, LangListEnum.russian);
      expect(large, [
        ...List.generate(50, (i) => 't$i'),
        ...List.filled(30, '__ANX_RATE_LIMIT__')
      ]);
      client.close();
    }
  });
  test('default fallback bounds concurrency and preserves successful siblings',
      () async {
    final provider = BoundedProvider();
    final texts = ['one', 'bad', ...List.generate(20, (i) => '$i')];
    final result = await provider.translateBatch(
        texts, LangListEnum.portuguese, LangListEnum.russian);
    expect(provider.maximum, lessThanOrEqualTo(4));
    expect(result, ['one', '__ANX_RETRY__', ...texts.skip(2)]);
  });
  test('cache identity separates language/provider and leaves CEFR local', () {
    final key = translationCacheLevel('word_wise', 'pt-PT', 'ru', 'ai');
    expect(key, isNot(translationCacheLevel('word_wise', 'pt-PT', 'en', 'ai')));
    expect(key, isNot(translationCacheLevel('word_wise', 'en', 'ru', 'ai')));
    expect(
        key,
        isNot(
            translationCacheLevel('word_wise', 'pt-PT', 'ru', 'microsoftApi')));
    expect(key, startsWith('word_wise:v2:'));
  });
  test(
      'coverage distinguishes missing/empty annotations and rejects changed source',
      () {
    const source = "Olá, d’água! a água.";
    final partial =
        WordWiseText(source, '[Olá|Привет|a1], d’água! a [água|вода|a1].');
    expect(partial.sourceMatches, isTrue);
    expect(partial.missingWords, ['d’água', 'a']);
    final complete = partial.repair(['[d’água|воды|b1]', '[a||0]']);
    expect(complete.missingWords, isEmpty);
    expect(complete.sourceMatches, isTrue);
    expect(complete.markedText,
        '[Olá|Привет|a1], [d’água|воды|b1]! [a||0] [água|вода|a1].');
    expect(WordWiseText(source, '[Oi|Привет|a1]').sourceMatches, isFalse);
    expect(
        WordWiseText('cafe\u0301 தமிழ்',
                '[["cafe\u0301","кофе","a1"],["தமிழ்","тамильский","b1"]]')
            .missingWords,
        isEmpty);
    expect(WordWiseText('Olá', '[Olá|]').missingWords, isEmpty);
    expect(isTranslationFailure(''), isTrue);
    expect(isTranslationFailure('__ANX_RATE_LIMIT__'), isTrue);
    expect(isTranslationFailure('Translation error: failed'), isTrue);
    expect(isTranslationFailure('привет'), isFalse);
  });
}
