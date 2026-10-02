import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/translation_cache.dart';
import 'package:anx_reader/enums/translation_mode.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUp(() async {
    storage = await Directory.systemTemp.createTemp('anx-refresh-test-');
    documentPath = storage.path;
    await Directory(path.join(storage.path, 'file')).create();
    await Directory(path.join(storage.path, 'cover')).create();
    SharedPreferences.setMockInitialValues({
      'customStoragePath': storage.path,
      'fullTextTranslateRpm': 12,
      'aiBatchSize': 17,
      'bookTranslationModes': '{"1":"interlinear"}',
    });
    await Prefs().initPrefs();
    sqfliteFfiInit();
  });
  tearDown(() async {
    await DBHelper.close();
    documentPath = '';
    await storage.delete(recursive: true);
  });

  test('fresh installation finishes schema creation before exposing database',
      () async {
    final db = await DBHelper().database;
    expect(await db.query('tb_translation_cache'), isEmpty);
    expect((await db.query('tb_groups')).single['id'], 0);
  });

  for (final version in [7, 8]) {
    test(
        'opens database v$version without losing books, notes or cached translations',
        () async {
      final seed = await databaseFactoryFfi.openDatabase(
        path.join(storage.path, 'databases', 'app_database.db'),
        options: OpenDatabaseOptions(
            version: version,
            onCreate: (db, _) async {
              await db.execute(createBookSQL);
              await db.execute(createNoteSQL);
              await db.insert('tb_books', {
                'id': 1,
                'title': 'Fixture',
                'last_read_position': 'epubcfi(/6/2!/4/2/1:4)',
              });
              await db.insert(
                  'tb_notes', {'id': 1, 'book_id': 1, 'content': 'Saved note'});
              if (version == 8) {
                await db.execute(createTranslationCacheSQL);
                await db.insert('tb_translation_cache', {
                  'book_id': 1,
                  'level': 'word_wise',
                  'original_text': 'ola',
                  'translated_text': '[ola|привет|a1]',
                });
              }
            }),
      );
      await seed.close();

      final db = await DBHelper().database;
      expect(await db.getVersion(), currentDbVersion);
      expect(await db.query('tb_vocabulary_words'), isEmpty);
      expect((await db.query('tb_books')).single['last_read_position'],
          'epubcfi(/6/2!/4/2/1:4)');
      expect((await db.query('tb_notes')).single['content'], 'Saved note');
      expect(await translationCacheDao.getTranslations(1, 'word_wise', ['ola']),
          version == 8 ? {'ola': '[ola|привет|a1]'} : isEmpty);
      await translationCacheDao
          .insertTranslations(1, 'word_wise', {'ola': '[ola|здравствуй|a1]'});
      expect(await translationCacheDao.getTranslations(1, 'word_wise', ['ola']),
          {'ola': '[ola|здравствуй|a1]'});
      expect(await translationCacheDao.countForBook(1), 1);
      expect(Prefs().aiRpm, 12);
      expect(Prefs().aiBatchSize, 17);
      expect(
          Prefs().getBookTranslationMode(1), TranslationModeEnum.interlinear);
    });
  }
}
