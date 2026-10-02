import 'dart:io';
import 'dart:convert';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/vocabulary.dart';
import 'package:anx_reader/dao/translation_cache.dart';
import 'package:anx_reader/models/vocabulary.dart';
import 'package:anx_reader/service/vocabulary/anki_export.dart';
import 'package:csv/csv.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/widgets/reading_page/vocabulary_word_dialog.dart';
import 'package:flutter/material.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new database includes independent vocabulary tables', () async {
    final dir = await Directory.systemTemp.createTemp('anx-vocabulary-test-');
    documentPath = dir.path;
    await Directory('${dir.path}/file').create();
    await Directory('${dir.path}/cover').create();
    SharedPreferences.setMockInitialValues({'customStoragePath': dir.path});
    await Prefs().initPrefs();
    try {
      final db = await DBHelper().database;
      expect(await db.query('tb_vocabulary_words'), isEmpty);
      expect(await db.query('tb_vocabulary_cards'), isEmpty);
      Future<String> save(
              {String context = 'Olá, mundo!',
              String source = 'pt-PT',
              int bookId = 1,
              VocabularyStatus status = VocabularyStatus.learning}) =>
          vocabularyDao.save(
              sourceLanguage: source,
              targetLanguage: 'ru',
              word: 'Olá',
              translation: 'привет, "мир"\nOlá!',
              contextText: context,
              bookId: bookId,
              bookTitle: 'Book',
              chapter: 'Chapter',
              cfi: 'epubcfi(/6/2!/4/2:0)',
              status: status);
      final id = await save();
      expect(await save(), id);
      await save(context: 'Outro exemplo', bookId: 2);
      expect(await save(bookId: 2), isNot(id));
      expect((await vocabularyDao.cards()).length, 3);
      expect((await vocabularyDao.cards(bookId: 2)).length, 2);
      expect(await vocabularyDao.statuses('pt-BR'), {'olá': 'learning'});
      expect(await vocabularyDao.statuses('en'), isEmpty);
      final card = (await vocabularyDao.cards(bookId: 1)).single;
      await vocabularyDao.setStatus(card.wordId, VocabularyStatus.known);
      expect(await vocabularyDao.statuses('pt'), {'olá': 'known'});
      expect(await vocabularyDao.cards(status: VocabularyStatus.learning),
          isEmpty);
      await vocabularyDao.setStatus(card.wordId, VocabularyStatus.learning);
      await translationCacheDao.clearAll();
      expect((await vocabularyDao.cards()).length, 3);
      final csv =
          utf8.decode(vocabularyAnkiCsv(await vocabularyDao.cards(bookId: 1)));
      expect(csv, startsWith('#separator:Comma\n#html:false\n'));
      final rows = const CsvToListConverter(shouldParseNumbers: false)
          .convert(csv.split('\n').skip(4).join('\n'));
      expect(rows.single[0], id);
      expect(rows.single[2], 'привет, "мир"\nOlá!');
      await vocabularyDao.editTranslation(id, 'новый перевод');
      expect((await vocabularyDao.cards(bookId: 1)).single.id, id);
      final blankId = await vocabularyDao.save(
          sourceLanguage: 'pt',
          targetLanguage: 'ru',
          word: 'novo',
          translation: '',
          contextText: 'novo',
          bookId: 1,
          bookTitle: 'Book',
          chapter: 'Chapter',
          cfi: '',
          status: VocabularyStatus.known);
      final blank = (await vocabularyDao.cards(query: 'novo')).single;
      expect(
          () =>
              vocabularyDao.setStatus(blank.wordId, VocabularyStatus.learning),
          throwsArgumentError);
      await vocabularyDao.editTranslation(blankId, 'новый');
      await vocabularyDao.setStatus(blank.wordId, VocabularyStatus.learning);
      expect((await vocabularyDao.cards(query: 'novo')).single.status,
          VocabularyStatus.learning);
      await DBHelper.close();
      final backupDir = await Directory('${dir.path}/backup/databases')
          .create(recursive: true);
      await File('${dir.path}/databases/app_database.db')
          .copy('${backupDir.path}/app_database.db');
      Prefs().customStoragePath = '${dir.path}/backup';
      expect(
          (await vocabularyDao.cards(query: 'Olá', bookId: 1))
              .single
              .translation,
          'новый перевод');
    } finally {
      await DBHelper.close();
      documentPath = '';
      await dir.delete(recursive: true);
    }
  });
  test(
      'keys preserve accents and normalize punctuation/apostrophes; auto is rejected',
      () {
    expect(vocabularyWordKey(' “D’Água!” '), "d'água");
    expect(vocabularyWordKey('Água'), isNot(vocabularyWordKey('Agua')));
    expect(vocabularyWordKey(' “cafe\u0301!” '), 'cafe\u0301');
    expect(vocabularyWordKey('தமிழ்!'), 'தமிழ்');
    expect(() => vocabularyLanguage('auto'), throwsArgumentError);
  });
  testWidgets(
      'word menu requires language/translation and saves the edited contextual card',
      (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('anx-word-menu-test-');
      documentPath = dir.path;
      await Directory('${dir.path}/file').create();
      await Directory('${dir.path}/cover').create();
      SharedPreferences.setMockInitialValues({'customStoragePath': dir.path});
      await Prefs().initPrefs();
      await L10n.delegate.load(const Locale('en'));
    });
    var source = LangListEnum.auto;
    try {
      await tester.pumpWidget(MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showVocabularyWordDialog(context,
                          book: Book.mock(),
                          word: 'Olá',
                          translation: '',
                          contextText: 'Olá, mundo!',
                          chapter: 'Chapter',
                          cfi: 'epubcfi(/6/2!/4/2:0)',
                          sourceLanguage: source,
                          targetLanguage: LangListEnum.russian),
                      child: const Text('Open'))))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I know this'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(await tester.runAsync(() => vocabularyDao.cards()), isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      source = LangListEnum.portuguese;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Learning'));
      await tester.pumpAndSettle();
      expect(
          find.text('Enter a translation to learn this word.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'привет');
      await tester.tap(find.text('Learning'));
      await tester.runAsync(() async {
        // Allow the actual SQLite transaction to finish outside the fake widget clock.
        for (var i = 0; i < 50 && (await vocabularyDao.cards()).isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final card = (await tester.runAsync(() => vocabularyDao.cards()))!.single;
      expect(card.translation, 'привет');
      expect(card.contextText, 'Olá, mundo!');
      expect(card.status, VocabularyStatus.learning);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await DBHelper.close();
        documentPath = '';
        await dir.delete(recursive: true);
      });
    }
  });
}
