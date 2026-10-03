import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('provider settings survive saving and key rotation', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    final provider = AiProvider(
      id: 'configured-provider',
      title: 'Fixture',
      url: 'https://example.invalid/v1',
      protocol: AiProtocol.claude,
      model: 'fixture-model',
      apiKeys: const [AiApiKey(id: 'fixture-key', key: 'test-key')],
      createdAt: DateTime.utc(2026, 10, 3),
    );

    Prefs().saveAiProviders([provider.copyWith(keyIndex: 1)]);
    final restored = AiProvider.fromJson(
      Prefs().getAiProviders().single as Map<String, dynamic>,
    );
    expect(restored, provider.copyWith(keyIndex: 1));
  });

  test(
      'selected provider configuration failure is not masked by legacy fallback',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    Prefs().selectedAiService = 'configured-provider';
    Prefs().saveAiProviders([
      const AiProvider(
        id: 'configured-provider',
        title: 'Fixture',
        url: 'https://example.invalid/v1',
        protocol: AiProtocol.openai,
        model: '',
        apiKeys: [AiApiKey(id: 'fixture-key', key: 'test-key')],
      ),
    ]);

    final response = await aiGenerateStream([
      ChatMessage.system('Classify the CEFR level of rapaz'),
    ]).last;

    expect(response, startsWith('Error:'));
    expect(response, contains('model is required'));
  });

  test('CEFR response survives persistence of the next API key', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      final chunk = {
        'id': 'fixture-completion',
        'object': 'chat.completion.chunk',
        'created': 1700000000,
        'model': 'fixture-model',
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': '{"rapaz":"A1"}'},
            'finish_reason': 'stop',
          }
        ],
      };
      request.response.write('data: ${jsonEncode(chunk)}\n\ndata: [DONE]\n\n');
      await request.response.close();
    });
    Prefs().selectedAiService = 'configured-provider';
    Prefs().saveAiProviders([
      {
        'id': 'configured-provider',
        'title': 'Fixture',
        'url': 'http://127.0.0.1:${server.port}/v1',
        'protocol': 'openai',
        'model': 'fixture-model',
        'apiKeys': [
          {'id': 'fixture-key', 'key': 'test-key'},
        ],
      },
    ]);

    final response = await HttpOverrides.runWithHttpOverrides(
      () => aiGenerateStream([
        ChatMessage.system('Classify the CEFR level of rapaz'),
      ]).last,
      _LoopbackHttpOverrides(),
    );

    expect(response, '{"rapaz":"A1"}');
    expect(requests, 1);
    expect(Prefs().getAiProviders().single['keyIndex'], 1);
  });
}
