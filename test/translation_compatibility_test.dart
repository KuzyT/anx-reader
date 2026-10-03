import 'dart:async';

import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/service/translate/ai.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain/langchain.dart';

class RecordingProvider extends AiTranslateProvider {
  final flags = <bool>[];

  @override
  Stream<String> translateStream(
      String text, LangListEnum from, LangListEnum to,
      {String? contextText, bool isFullText = false, WidgetRef? ref}) async* {
    flags.add(isFullText);
    yield '...';
    yield '<think>Intermediate [JSON] should be hidden</think>\nперевод';
  }
}

class RecordingDefaultProvider extends TranslateServiceProvider {
  final flags = <bool>[];
  @override
  TranslateService get service => TranslateService.ai;
  @override
  String getLabel(BuildContext context) => 'test';
  @override
  Widget translate(String text, LangListEnum from, LangListEnum to,
          {String? contextText, WidgetRef? ref}) =>
      const SizedBox();
  @override
  Stream<String> translateStream(
      String text, LangListEnum from, LangListEnum to,
      {String? contextText, bool isFullText = false, WidgetRef? ref}) async* {
    flags.add(isFullText);
    yield '...';
    yield 'перевод';
  }
}

class DeferredProvider extends AiTranslateProvider {
  final result = Completer<String>();
  bool started = false;
  @override
  Future<String> translateTextOnly(
      String text, LangListEnum from, LangListEnum to,
      {String? contextText, bool isFullText = false, WidgetRef? ref}) {
    started = true;
    return result.future;
  }
}

class ControlledChatModel extends FakeChatModel {
  ControlledChatModel(this.source) : super(responses: ['unused']);
  final StreamController<ChatResult> source;
  @override
  Stream<ChatResult> stream(PromptValue input,
          {FakeChatModelOptions? options}) =>
      source.stream;
}

void main() {
  test('cancel also invalidates classification waiting for its quiet slot',
      () async {
    var started = false;
    final classification = AiTranslateProvider.classifyInBackground(() async {
      started = true;
      return 'unused';
    });
    AiTranslateProvider.cancelTranslation();
    await expectLater(classification, throwsStateError);
    expect(started, isFalse);
  });
  test('old runner cleanup never cancels a new model subscription', () async {
    final cleanup = Completer<void>();
    final oldSource =
        StreamController<ChatResult>(onCancel: () => cleanup.future);
    var newCancelled = false;
    final newSource = StreamController<ChatResult>(onCancel: () {
      newCancelled = true;
    });
    final runner = CancelableLangchainRunner();
    final prompt = PromptValue.string('test');
    final old = runner
        .stream(model: ControlledChatModel(oldSource), prompt: prompt)
        .listen((_) {}, onError: (Object _) {});
    runner.cancel();
    final current = runner
        .stream(model: ControlledChatModel(newSource), prompt: prompt)
        .listen((_) {}, onError: (Object _) {});
    await Future<void>.delayed(Duration.zero);
    cleanup.complete();
    await Future<void>.delayed(Duration.zero);
    final cancelledByOldCleanup = newCancelled;
    await current.cancel();
    await old.cancel();
    await oldSource.close();
    await newSource.close();
    expect(cancelledByOldCleanup, isFalse);
  });
  test(
      'cancelled old batch cannot release a newer batch lock or return cacheable text',
      () async {
    final old = DeferredProvider(),
        current = DeferredProvider(),
        next = DeferredProvider();
    Future<List<String>> run(DeferredProvider provider) => provider
        .translateBatch(['ola'], LangListEnum.portuguese, LangListEnum.russian);
    final oldRequest = run(old);
    await Future<void>.delayed(Duration.zero);
    AiTranslateProvider.cancelTranslation();
    final currentRequest = run(current);
    await Future<void>.delayed(Duration.zero);
    old.result.complete('Cancelled by user or system');
    final oldResponse = await oldRequest;
    final nextRequest = run(next);
    await Future<void>.delayed(Duration.zero);
    final prematureStart = next.started;
    current.result.complete('current');
    await currentRequest;
    next.result.complete('next');
    await nextRequest;
    expect(oldResponse, ['__ANX_CANCELLED__']);
    expect(prematureStart, isFalse);
  });
  test('batch JSON parses the answer, excluding upstream reasoning envelope',
      () {
    final provider = AiTranslateProvider();
    expect(
        provider.parseJsonArrayFromResponse(
            '<think>Example: ["wrong"]</think>\n["correct"]', 1),
        ['correct']);
    expect(
        provider.parseJsonArrayFromResponse(
            '```json\n[[["ola","привет"]]]\n```', 1),
        ['[["ola","привет"]]']);
    expect(provider.parseJsonArrayFromResponse('["one"]', 2),
        ['one', '__ANX_RETRY__']);
  });

  test('single full AI batch preserves upstream full-text prompt selection',
      () async {
    final provider = RecordingProvider();
    expect(
        await provider.translateBatch(
            ['ola'], LangListEnum.portuguese, LangListEnum.russian),
        ['перевод']);
    expect(provider.flags, [true]);
  });

  test('default batch forwards full-text flag and waits for final stream value',
      () async {
    final provider = RecordingDefaultProvider();
    expect(
        await provider.translateBatch(
            ['ola', 'mundo'], LangListEnum.portuguese, LangListEnum.russian),
        ['перевод', 'перевод']);
    expect(provider.flags, [true, true]);
  });
}
